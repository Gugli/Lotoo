pub const lib_options = [_][]const u8{
    "MINIZ_NO_DEFLATE_APIS",
    "MINIZ_NO_STDIO",
    "MINIZ_NO_MALLOC",
    "MINIZ_NO_TIME",
};

const miniz = @cImport({
    for (lib_options) |option| {
        @cDefine(option, {});
    }
    @cInclude("miniz.h");
});
const std = @import("std");

const UserData = ?*anyopaque;
const Ptr = ?*anyopaque;

const ptr_align: u8 = 3;

const SAllocHeader = struct {
    Size: usize,
};

fn Alloc_PtrFromSlice(bytes: []u8) Ptr {
    const ptr_bytes: [*]u8 = @ptrCast(bytes);
    const header: *SAllocHeader = @alignCast(@ptrCast(ptr_bytes));
    header.Size = (bytes.len - @sizeOf(SAllocHeader));
    return @ptrCast(bytes[@sizeOf(SAllocHeader)..]);
}

fn Alloc_PtrToSlice(ptr: Ptr) []u8 {
    const ptr_bytes: [*]u8 = @ptrCast(ptr);
    const header: *SAllocHeader = @alignCast(@ptrCast(ptr_bytes - @sizeOf(SAllocHeader)));
    const bytes_count = header.Size;
    const bytes: []u8 = ptr_bytes[0..bytes_count];
    return bytes;
}

fn Callback_Alloc(userdata: UserData, count: usize, size: usize) callconv(.C) Ptr {
    const zip: *Zip = @alignCast(@ptrCast(userdata));
    const totalsize = size * count + @sizeOf(SAllocHeader);
    const bytes = zip.allocator.vtable.alloc(zip.allocator.ptr, totalsize, ptr_align, @returnAddress()) orelse return null;
    return Alloc_PtrFromSlice(bytes[0..totalsize]);
}

fn Callback_Realloc(userdata: UserData, ptr: Ptr, count: usize, size: usize) callconv(.C) Ptr {
    const zip: *Zip = @alignCast(@ptrCast(userdata));
    if (ptr == null) {
        return Callback_Alloc(userdata, count, size);
    }

    const prev_bytes = Alloc_PtrToSlice(ptr);
    const totalsize = size * count + @sizeOf(SAllocHeader);
    const success_inplace = zip.allocator.vtable.resize(zip.allocator.ptr, prev_bytes, ptr_align, totalsize, @returnAddress());
    if (success_inplace) {
        return ptr;
    }
    const newptr = Callback_Alloc(userdata, count, size);
    //@memcpy(prev_bytes, newptr);
    return newptr;
}
fn Callback_Free(userdata: UserData, ptr: Ptr) callconv(.C) void {
    const zip: *Zip = @alignCast(@ptrCast(userdata));
    const bytes = Alloc_PtrToSlice(ptr);
    zip.allocator.vtable.free(zip.allocator.ptr, bytes, ptr_align, @returnAddress());
}
fn Callback_Read(userdata: UserData, offset: u64, buffer: ?*anyopaque, buffer_size: usize) callconv(.C) usize {
    const loader: *Loader = @alignCast(@ptrCast(userdata));
    const bytes: [*c]u8 = @ptrCast(buffer orelse return 0);
    const slice: []u8 = bytes[0..buffer_size];
    return loader.read(loader.userdata, offset, slice) catch return 0;
}
const in_buffer_size = 16 * 1024;

const Zip = struct {
    allocator: std.mem.Allocator,
    archive: miniz.mz_zip_archive,
};

pub const Loader = struct {
    userdata: ?*anyopaque,
    read: *const fn (userdata: ?*anyopaque, offset: u64, bytes: []u8) error{ReadError}!u32,
    total_size: usize,
};

pub fn Archive_Load(allocator: std.mem.Allocator, loader: *Loader) !*Zip {
    const zip = allocator.create(Zip) catch |err| return err;
    zip.allocator = allocator;

    var archive: miniz.mz_zip_archive = undefined;
    miniz.mz_zip_zero_struct(&archive);

    archive.m_pAlloc_opaque = @ptrCast(zip);
    archive.m_pAlloc = Callback_Alloc;
    archive.m_pFree = Callback_Free;
    archive.m_pRealloc = Callback_Realloc;

    archive.m_pIO_opaque = @ptrCast(loader);
    archive.m_pRead = Callback_Read;
    archive.m_pWrite = null;
    archive.m_pNeeds_keepalive = null;

    const flags = miniz.MZ_ZIP_FLAG_COMPRESSED_DATA;
    switch (miniz.mz_zip_reader_init(&archive, loader.total_size, flags)) {
        miniz.MZ_TRUE => {},
        miniz.MZ_FALSE => return error.OutOfMemory,
        else => unreachable,
    }
    zip.archive = archive;

    return zip;
}

pub fn Archive_GetFilesCount(zip: *Zip) !u32 {
    return miniz.mz_zip_reader_get_num_files(&zip.archive);
}

pub fn File_IsDir(zip: *Zip, i: u32) !bool {
    switch (miniz.mz_zip_reader_is_file_a_directory(&zip.archive, i)) {
        miniz.MZ_TRUE => return true,
        miniz.MZ_FALSE => return false,
        else => unreachable,
    }
}

pub fn File_GetName(zip: *Zip, i: u32, allocator: std.mem.Allocator) ![*:0]u8 {
    var stat: miniz.mz_zip_archive_file_stat = undefined;
    switch (miniz.mz_zip_reader_file_stat(&zip.archive, i, &stat)) {
        miniz.MZ_TRUE => {},
        miniz.MZ_FALSE => return error.InvalidParameter,
        else => unreachable,
    }
    const cname: [*:0]u8 = @ptrCast(&stat.m_filename);
    const slice: []u8 = std.mem.span(cname);
    const result = allocator.alloc(u8, slice.len + 1) catch return error.InvalidParameter;
    @memcpy(result[0..slice.len], slice);
    result[slice.len] = 0;
    return @ptrCast(result.ptr);
}
const File_GetBytes_Param = struct {
    bytes: []u8,
};
fn File_GetBytes_Callback(userdata: ?*anyopaque, offset: u64, buffer: ?*const anyopaque, buffersize: usize) callconv(.C) usize {
    const param: *File_GetBytes_Param = @alignCast(@ptrCast(userdata));
    const dest_bytes: []u8 = param.bytes;
    const source_bytes: [*c]const u8 = @ptrCast(buffer orelse return 0);
    const source_slice = source_bytes[0..buffersize];
    if (buffersize + offset > dest_bytes.len) return 0;
    @memcpy(dest_bytes[offset..], source_slice);
    return source_slice.len;
}
pub fn File_GetBytes(zip: *Zip, i: u32, allocator: std.mem.Allocator) ![]u8 {
    var stat: miniz.mz_zip_archive_file_stat = undefined;
    switch (miniz.mz_zip_reader_file_stat(&zip.archive, i, &stat)) {
        miniz.MZ_TRUE => {},
        miniz.MZ_FALSE => return error.InvalidParameter,
        else => unreachable,
    }
    const bytes = allocator.alloc(u8, stat.m_uncomp_size) catch return error.OutOfMemory;
    const param: File_GetBytes_Param = .{
        .bytes = bytes,
    };

    switch (miniz.mz_zip_reader_extract_to_callback(&zip.archive, i, &File_GetBytes_Callback, @constCast(@ptrCast(&param)), 0)) {
        miniz.MZ_TRUE => {},
        miniz.MZ_FALSE => return error.InvalidParameter,
        else => unreachable,
    }
    return bytes;
}

pub fn Archive_Unload(zip: *Zip) !void {
    switch (miniz.mz_zip_reader_end(&zip.archive)) {
        miniz.MZ_TRUE => {},
        miniz.MZ_FALSE => return error.InvalidParameter,
        else => unreachable,
    }

    zip.allocator.destroy(zip);
}
