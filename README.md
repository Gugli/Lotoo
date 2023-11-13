# Lotoo

Lotoo is a piece of software that aims to provide easy implementation of bingo-like apps.

## Licensing

Lotoo uses what is commonly referred to as **dual-licensing**. That means you have two ways to use it.
 - If you're doing FOSS, it is distributed under the GPLv3, which is likely to be compatible with whatever license you are using (but you still have to check). 
 - If you want to use this lib in cases where GPLv3 don't apply (i.e closed-source/commercial/propietary software), you can contact me. I am ready to grant specific commercial licenses.

Legalese explaining this can be found in LICENSE.md.
GPLv3 full text can be found in LICENSE_GPL3.md.

## Usage 

You can find the API C headers in "lotoo.h".
You can find and exemple of usage in "src/cli.c". This is a simple CLI implementation of Lotoo.

### Concepts

Every action takes place relative to a `TLotoo_Context`. 

A `TLotoo_Quizz` represents a question (binary data) and the corresponding answer (text data).
E.G. : The question can be a MP3 file for "blind-test" bingoes. The answer is the text will appear on the `TLotoo_Card`s, most likely "Singer + name of the song".

`TLotoo_Pack`s are zip files containing `TLotoo_Quizz`es. You can load them.

You can generate `TLotoo_Card`s with various popular formats. A `TLotoo_Card` is tied to it's `TLotoo_Pack` of origin.
`TLotoo_Card`s are grids. Some cases are left empty, and other contains answers to specific `TLotoo_Quizz`es.
`TLotoo_Card`s have are uniquely identified by their index. 

Players get one or more cards of the same kind (printed, or via any adapted means). 
The game host can then create a `TLotoo_Game`.
The host can run the `TLotoo_Quizz`es one by one. Players check the answers they know.
The host can check the `TLotoo_Card` status at any time, to see if one row/column of the card is complete, or if the whole card is complete.

### Integration

To integrate Lotoo, you have to :
 - allocate a `SLotoo_API` struct
 - call `lotoo_init`, with a pointer to this struct as the parameter
 - `lotoo_init` will fill the struct with all the entry points.
 - you should check that the result of `lotoo_init` matches `LOTOO_API_VERSION`. If it does not, you are probably using outdated lib files.
 
Then you can call the functions from their pointers in the `SLotoo_API` struct :
 - create a context with `Context_Init`. You can specify you own page allocator, or use the default C one.
 - with this context, you can manage packs, cards and games.
 
## Building

### Dependences

Lotoo uses "miniz" (https://github.com/richgel999/miniz). This allows reading zip files.

You should be able to get all the dependencies by running "deps.bat"

### Zig build

`zig build` should do everything you need.
