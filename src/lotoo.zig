const API = @cImport(@cInclude("lotoo.h"));
const zip = @import("zip");
const std = @import("std");

const SContext = struct {
    custom_page_allocator: ?API.TLotoo_PageAllocator,
    page_allocator: std.mem.Allocator,
    packs_allocator: std.heap.ArenaAllocator,
    packs: std.ArrayList(*SPack),
    game_pool: std.heap.MemoryPool(SGame),
};

const SQuizz = struct {
    name: [*:0]u8,
    data: []u8,
};

const SPack = struct {
    id: API.TLotoo_PackId,
    quizzes: []SQuizz,
};

const SGame = struct {
    context: *SContext,
    pack: *SPack,
    cardtype: API.TLotoo_CardType,
    order: []u32,
};

const SSquare = ?u32;

const SCard = struct {
    squares: [27]SSquare,
};

const SCardConfig = struct {
    generate: *const fn (pack: *SPack, rng: std.rand.Random) error{InvalidPack}!SCard,
    check: *const fn (pack: *SPack, rng: std.rand.Random, called: []u32) error{InvalidPack}!API.TLotoo_CardStatus,
};

fn ContextPtrGet(_Context: ?*API.TLotoo_Context) !*SContext {
    const Context = _Context orelse return error.InvalidPointer;
    return @alignCast(@ptrCast(Context));
}

fn PackPtrGet(_Pack: ?*API.TLotoo_Pack) *SPack {
    return @alignCast(@ptrCast(_Pack));
}

fn GamePtrGet(_Game: ?*API.TLotoo_Game) *SGame {
    return @alignCast(@ptrCast(_Game));
}

fn callback_alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    _ = ptr_align;
    _ = ret_addr;
    const custom_allocator: *API.TLotoo_PageAllocator = @alignCast(@ptrCast(ctx));
    const page_size = custom_allocator.PageSize;
    std.debug.assert(len > 0);
    if (len > std.math.maxInt(usize) - (page_size - 1)) return null;
    const aligned_len = std.mem.alignForward(usize, len, page_size);
    const alloc_func = custom_allocator.AllocPages orelse return null;
    return @ptrCast(alloc_func(custom_allocator.UserData, aligned_len));
}

fn callback_resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    _ = new_len;
    _ = ret_addr;
    _ = buf_align;
    _ = buf;
    _ = ctx;
    return false;
}

fn callback_free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    const custom_allocator: *API.TLotoo_PageAllocator = @alignCast(@ptrCast(ctx));
    _ = ret_addr;
    _ = buf_align;
    const free_func = custom_allocator.FreePages orelse return;
    free_func(custom_allocator.UserData, @ptrCast(buf));
}

const custom_allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = &callback_alloc,
    .resize = &callback_resize,
    .free = &callback_free,
};

fn Context_Init(_PageAllocator: ?*API.TLotoo_PageAllocator) callconv(.C) ?*API.TLotoo_Context {
    var context: *SContext = undefined;
    if (_PageAllocator) |custom_allocator| {
        const alloc_func = custom_allocator.AllocPages orelse return null;
        const context_alloc: ?*anyopaque = alloc_func(custom_allocator.UserData, @sizeOf(SContext));
        const newcontext: *SContext = @alignCast(@ptrCast(context_alloc orelse return null));
        context = newcontext;
        context.custom_page_allocator = custom_allocator.*;
        context.page_allocator = std.mem.Allocator{ .ptr = &context.custom_page_allocator, .vtable = &custom_allocator_vtable };
    } else {
        context = std.heap.page_allocator.create(SContext) catch return null;
        context.custom_page_allocator = null;
        context.page_allocator = std.heap.page_allocator;
    }

    context.packs_allocator = std.heap.ArenaAllocator.init(context.page_allocator);
    context.packs = @TypeOf(context.packs).init(context.packs_allocator.allocator());
    context.game_pool = @TypeOf(context.game_pool).init(context.page_allocator);

    return @alignCast(@ptrCast(context));
}

fn Context_Clean(_context: ?*API.TLotoo_Context) callconv(.C) void {
    const context = ContextPtrGet(_context) catch return;
    context.game_pool.deinit();
    context.packs.deinit();
    var arena = context.packs_allocator;
    arena.deinit();

    if (context.custom_page_allocator) |custom_allocator| {
        const free_func = custom_allocator.FreePages orelse return;
        free_func(custom_allocator.UserData, context);
    } else {
        std.heap.page_allocator.destroy(context);
    }
}

fn LoadPack_Read(userdata: ?*anyopaque, offset: u64, buffer: []u8) !u32 {
    const packloader: *API.TLotoo_PackLoader = @alignCast(@ptrCast(userdata));
    if (buffer.len == 0) return error.ReadError;
    const readfunc = packloader.Read orelse return error.ReadError;
    const len: u32 = @intCast(buffer.len);
    return readfunc(packloader.UserData, offset, @ptrCast(buffer), len);
}

fn Context_LoadPack(_context: ?*API.TLotoo_Context, _PackLoader: ?*API.TLotoo_PackLoader) callconv(.C) ?*API.TLotoo_Pack {
    const context = ContextPtrGet(_context) catch return null;
    const PackLoader = _PackLoader orelse return null;
    var loader: zip.Loader = .{
        .userdata = PackLoader,
        .read = &LoadPack_Read,
        .total_size = PackLoader.TotalSize,
    };

    var zip_allocator = std.heap.ArenaAllocator.init(context.page_allocator);
    defer zip_allocator.deinit();

    const pack = zip.Archive_Load(zip_allocator.allocator(), &loader) catch return null;
    defer zip.Archive_Unload(pack) catch {};

    const pack_allocator = context.packs_allocator.allocator();
    const new_pack = pack_allocator.create(SPack) catch return null;

    const zipfilescount = zip.Archive_GetFilesCount(pack) catch return null;
    var quizzescount: u32 = 0;
    var quizzes: []SQuizz = undefined;
    const Pass = enum { ParseInfo, ReadQuizzes };
    inline for (.{ Pass.ParseInfo, Pass.ReadQuizzes }) |pass| {
        var quizz_index: u32 = 0;
        if (pass == Pass.ReadQuizzes) {
            quizzes = pack_allocator.alloc(SQuizz, quizzescount) catch return null;
        }
        for (0..zipfilescount) |i| {
            const file_index: u32 = @intCast(i);
            const name = zip.File_GetName(pack, file_index, pack_allocator) catch return null;
            const data = zip.File_GetBytes(pack, file_index, pack_allocator) catch return null;
            if (std.mem.eql(u8, std.mem.span(name), "info.txt")) {
                // Parse pack infos
                if (pass == Pass.ParseInfo) {}
            } else {
                const is_dir = zip.File_IsDir(pack, file_index) catch return null;
                if (!is_dir) {
                    if (pass == Pass.ParseInfo) {
                        quizzescount += 1;
                    } else if (pass == Pass.ReadQuizzes) {
                        const quizz = &quizzes[quizz_index];
                        quizz.name = name;
                        quizz.data = data;
                    }
                    quizz_index += 1;
                }
            }
        }
    }
    new_pack.id = 0;
    new_pack.quizzes = quizzes;

    const new_pack_addr = context.packs.addOne() catch return null;
    new_pack_addr.* = new_pack;
    return @ptrCast(new_pack);
}

fn Pack_Id_Get(_Pack: ?*API.TLotoo_Pack) callconv(.C) API.TLotoo_PackId {
    const pack = PackPtrGet(_Pack);
    return pack.id;
}
fn Pack_Quizzes_GetCount(_Pack: ?*API.TLotoo_Pack) callconv(.C) API.TLotoo_Index {
    const pack = PackPtrGet(_Pack);
    return @intCast(pack.quizzes.len);
}

fn quizz_fill(quizz_src: SQuizz, quizz_dst: *API.TLotoo_Quizz) void {
    quizz_dst.Name = quizz_src.name;
    quizz_dst.Data = quizz_src.data.ptr;
    quizz_dst.DataLen = @intCast(quizz_src.data.len);
}

fn Pack_Quizzes_Get(_Pack: ?*API.TLotoo_Pack, _QuizzIndex: API.TLotoo_Index, _Quizz: ?*API.TLotoo_Quizz) callconv(.C) API.TLotoo_Bool {
    const quizz_dst = _Quizz orelse return 0;
    const pack = PackPtrGet(_Pack);
    if (_QuizzIndex >= pack.quizzes.len) return 0;
    const quizz_src = pack.quizzes[_QuizzIndex];
    quizz_fill(quizz_src, quizz_dst);
    return 1;
}

fn cardtool_getrandquizzes(comptime count: usize, pack: *SPack, rng: std.rand.Random) ![count]u32 {
    var indices: [count]u32 = undefined;
    for (0..count) |i| {
        if (pack.quizzes.len <= i) return error.InvalidPack;

        var r = rng.intRangeAtMost(u32, 0, @intCast(pack.quizzes.len - i - 1));
        while (true) {
            var is_already_picked: bool = false;
            for (0..i) |j| {
                if (indices[j] == r) {
                    is_already_picked = true;
                    break;
                }
            }
            if (!is_already_picked)
                break;
            r = r + 1;
        }
        indices[i] = r;
    }

    return indices;
}

fn card_check_called(called: []u32, i: u32) bool {
    for (called) |i_called| {
        if (i_called == i) {
            return true;
        }
    }
    return false;
}

fn card_check_row(status: []bool, first: u32, colcount: u32) bool {
    for (0..colcount) |i| {
        if (!status[i + first * colcount]) {
            return false;
        }
    }
    return true;
}

fn card_check_col(status: []bool, first: u32, colcount: u32) bool {
    for (0..(status.len / colcount)) |i| {
        if (!status[first + i * colcount]) {
            return false;
        }
    }
    return true;
}

fn cardconfig_oneline1x5_generate(pack: *SPack, rng: std.rand.Random) !SCard {
    var card: SCard = undefined;
    card.squares = [_]SSquare{null} ** 27;
    const quizzes = try cardtool_getrandquizzes(5, pack, rng);
    for (0..5) |i| card.squares[i] = quizzes[i];
    return card;
}
fn cardconfig_oneline1x5_check(pack: *SPack, rng: std.rand.Random, called: []u32) !API.TLotoo_CardStatus {
    const quizzes = try cardtool_getrandquizzes(5, pack, rng);
    for (quizzes) |i| {
        if (!card_check_called(called, i))
            return API.ELotoo_CardStatus_Nothing;
    }
    return API.ELotoo_CardStatus_FullCard;
}

fn cardconfig_usstyle5x5_generate(pack: *SPack, rng: std.rand.Random) !SCard {
    var card: SCard = undefined;
    card.squares = [_]SSquare{null} ** 27;
    const quizzes = try cardtool_getrandquizzes(24, pack, rng);
    for (0..25) |i| card.squares[i] = if (i < 12) quizzes[i] else if (i > 12) quizzes[i - 1] else null;
    return card;
}

fn cardconfig_usstyle5x5_check_col(status: [25]bool, i: u32) [5]bool {
    var r: [5]bool = undefined;
    for (0..5) |j| {
        r[j] = status[i + j * 5];
    }
    return r;
}

fn cardconfig_usstyle5x5_check(pack: *SPack, rng: std.rand.Random, called: []u32) !API.TLotoo_CardStatus {
    const quizzes = try cardtool_getrandquizzes(24, pack, rng);
    var status: [25]bool = undefined;
    status[12] = true;
    var count: u32 = 0;
    for (quizzes, 0..) |q, i| {
        const is_called = card_check_called(called, q);
        status[if (i < 12) i else i + 1] = is_called;
        if (is_called) count += 1;
    }
    if (count == 24) return API.ELotoo_CardStatus_FullCard;
    if (card_check_row(&status, 0, 5)) return API.ELotoo_CardStatus_OneLine;
    if (card_check_row(&status, 1, 5)) return API.ELotoo_CardStatus_OneLine;
    if (card_check_row(&status, 2, 5)) return API.ELotoo_CardStatus_OneLine;
    if (card_check_row(&status, 3, 5)) return API.ELotoo_CardStatus_OneLine;
    if (card_check_row(&status, 4, 5)) return API.ELotoo_CardStatus_OneLine;

    if (card_check_col(&status, 0, 5)) return API.ELotoo_CardStatus_OneColumn;
    if (card_check_col(&status, 1, 5)) return API.ELotoo_CardStatus_OneColumn;
    if (card_check_col(&status, 2, 5)) return API.ELotoo_CardStatus_OneColumn;
    if (card_check_col(&status, 3, 5)) return API.ELotoo_CardStatus_OneColumn;
    if (card_check_col(&status, 4, 5)) return API.ELotoo_CardStatus_OneColumn;

    return API.ELotoo_CardStatus_Nothing;
}

fn cardconfig_eustyle3x9_generate(pack: *SPack, rng: std.rand.Random) !SCard {
    var card: SCard = undefined;
    card.squares = [_]SSquare{null} ** 27;
    const quizzes = try cardtool_getrandquizzes(15, pack, rng);

    for (0..3) |line_index| {
        var line: [9]?u32 = undefined;
        for (0..line.len) |i| {
            line[i] = if (i < 5) quizzes[i + line_index * 5] else null;
        }
        rng.shuffle(?u32, &line);
        for (line, 0..) |square, i| {
            card.squares[i + line_index * 9] = square;
        }
    }
    return card;
}
fn cardconfig_eustyle3x9_check(pack: *SPack, rng: std.rand.Random, called: []u32) !API.TLotoo_CardStatus {
    const quizzes = try cardtool_getrandquizzes(15, pack, rng);
    var status: [15]bool = undefined;
    var count: u32 = 0;
    for (quizzes, 0..) |q, i| {
        const is_called = card_check_called(called, q);
        if (is_called) count += 1;
        status[i] = is_called;
    }
    if (count == 15) return API.ELotoo_CardStatus_FullCard;
    if (card_check_row(&status, 0, 5)) return API.ELotoo_CardStatus_OneLine;
    if (card_check_row(&status, 1, 5)) return API.ELotoo_CardStatus_OneLine;
    if (card_check_row(&status, 2, 5)) return API.ELotoo_CardStatus_OneLine;
    return API.ELotoo_CardStatus_Nothing;
}

fn cardconfig_get(card_type: API.TLotoo_CardType) SCardConfig {
    switch (card_type) {
        API.ELotoo_CardType_OneLine1x5 => {
            return .{
                .generate = cardconfig_oneline1x5_generate,
                .check = cardconfig_oneline1x5_check,
            };
        },
        API.ELotoo_CardType_USStyle5x5 => {
            return .{
                .generate = cardconfig_usstyle5x5_generate,
                .check = cardconfig_usstyle5x5_check,
            };
        },
        API.ELotoo_CardType_EUStyle3x9 => {
            return .{
                .generate = cardconfig_eustyle3x9_generate,
                .check = cardconfig_eustyle3x9_check,
            };
        },
        else => unreachable,
    }
}

fn card_fill(pack: *SPack, src: *const SCard, dst: *API.TLotoo_Card) void {
    for (src.squares, 0..) |square, i| {
        const quizz: ?*SQuizz = if (square) |s| &pack.quizzes[s] else null;
        const name: ?[*:0]u8 = if (quizz) |q| q.name else null;
        dst.Squares[i].Name = name;
    }
}

fn Pack_Card_Get(_Pack: ?*API.TLotoo_Pack, _CardType: API.TLotoo_CardType, _CardIndex: API.TLotoo_Index, _Card: ?*API.TLotoo_Card) callconv(.C) API.TLotoo_Bool {
    const card_dst = _Card orelse return 0;
    const pack = PackPtrGet(_Pack);
    const cardconfig = cardconfig_get(_CardType);
    var RNG_State = std.rand.DefaultPrng.init(_CardIndex);
    const card_src = cardconfig.generate(pack, RNG_State.random()) catch return 0;
    card_fill(pack, &card_src, card_dst);
    return 1;
}

fn Game_Init(_context: ?*API.TLotoo_Context, _Pack: ?*API.TLotoo_Pack, _CardType: API.TLotoo_CardType, _Seed: API.TLotoo_Seed) callconv(.C) ?*API.TLotoo_Game {
    const context = ContextPtrGet(_context) catch return null;
    const game = context.game_pool.create() catch return null;
    const pack = PackPtrGet(_Pack orelse return null);
    game.context = context;
    game.pack = pack;
    game.cardtype = _CardType;

    // generate permutation
    game.order = context.page_allocator.alloc(u32, game.pack.quizzes.len) catch return null;
    for (0..game.order.len) |i| {
        game.order[i] = @intCast(i);
    }
    var RNG = std.rand.DefaultPrng.init(_Seed);
    RNG.random().shuffle(u32, game.order);

    return @alignCast(@ptrCast(game));
}

fn Game_Quizzes_GetCount(_Game: ?*API.TLotoo_Game) callconv(.C) API.TLotoo_Index {
    const game = GamePtrGet(_Game);
    return @intCast(game.order.len);
}

fn Game_Quizzes_Get(_Game: ?*API.TLotoo_Game, _Index: API.TLotoo_Index, _Quizz: ?*API.TLotoo_Quizz) callconv(.C) API.TLotoo_Bool {
    const game = GamePtrGet(_Game);
    const quizz_dst = _Quizz orelse return 0;
    const quizz_index = game.order[_Index];
    const quizz_src = game.pack.quizzes[quizz_index];
    quizz_fill(quizz_src, quizz_dst);
    return 1;
}

fn Game_CheckCardStatus(_Game: ?*API.TLotoo_Game, _LatestQuizzIndex: API.TLotoo_Index, _CardIndex: API.TLotoo_Index) callconv(.C) API.TLotoo_CardStatus {
    const game = GamePtrGet(_Game);
    const pack = game.pack;
    const cardconfig = cardconfig_get(game.cardtype);
    var RNG_State = std.rand.DefaultPrng.init(_CardIndex);
    return cardconfig.check(pack, RNG_State.random(), game.order[0 .. _LatestQuizzIndex + 1]) catch return API.ELotoo_CardStatus_Nothing;
}

fn Game_Clean(_context: ?*API.TLotoo_Context, _Game: ?*API.TLotoo_Game) callconv(.C) void {
    const context = ContextPtrGet(_context) catch return;
    const game = GamePtrGet(_Game);
    std.testing.expect(game.context == context) catch return;

    context.game_pool.destroy(game);
}

export fn lotoo_init(_API: *API.TLotoo_API) callconv(.C) c_uint {
    _API.* = std.mem.zeroes(API.TLotoo_API);

    _API.Context_Init = Context_Init;
    _API.Context_LoadPack = Context_LoadPack;
    _API.Context_Clean = Context_Clean;

    _API.Pack_Id_Get = Pack_Id_Get;
    _API.Pack_Quizzes_GetCount = Pack_Quizzes_GetCount;
    _API.Pack_Quizzes_Get = Pack_Quizzes_Get;
    _API.Pack_Card_Get = Pack_Card_Get;

    _API.Game_Init = Game_Init;
    _API.Game_Quizzes_GetCount = Game_Quizzes_GetCount;
    _API.Game_Quizzes_Get = Game_Quizzes_Get;
    _API.Game_CheckCardStatus = Game_CheckCardStatus;
    _API.Game_Clean = Game_Clean;

    return API.LOTOO_API_VERSION;
}

export fn lotoo_clean(_API: *API.TLotoo_API) callconv(.C) void {
    _API.* = std.mem.zeroes(API.TLotoo_API);
}
