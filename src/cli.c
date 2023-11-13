#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#ifdef USE_CUSTOM_WIN32_ALLOC 
#   include <windows.h>
#endif

#include "../lotoo.h"

#ifdef USE_CUSTOM_WIN32_ALLOC 
void* AllocPages(void* _UserData, unsigned long long _Size) {
    return VirtualAlloc( 0, _Size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE );
}

void FreePages(void* _UserData, void* _Ptr) {
    VirtualFree(_Ptr, 0, MEM_RELEASE);
}
#endif

#define IsPrefix(__P, __Str) (strncmp(__Str, __P, strlen(__P)) == 0) 
typedef struct {
    FILE* File;
} TFileReader ;

unsigned int CliReadFile(void* _UserData, unsigned long long _Offset, unsigned char* _Buffer, unsigned int _BufferSize ) {
    TFileReader* R = (TFileReader*)_UserData;
    _fseeki64(R->File, _Offset, SEEK_SET);
    return fread(_Buffer, 1, _BufferSize, R->File);
}

void PrintCard(TLotoo_CardType _Type, const TLotoo_Card* _Card)
{
    unsigned int max, columns; 
    switch(_Type){
        case ELotoo_CardType_OneLine1x5: max = 5; columns = 5; break;
        case ELotoo_CardType_USStyle5x5: max = 25; columns = 5; break;
        case ELotoo_CardType_EUStyle3x9: max = 27; columns = 9; break;
        default : max = -1; break;
    } 
    if(max != -1) {
        printf("\t[");
        for (unsigned int i = 0; i<max; i++) {
            if(i%columns == 0) {
                if(i) printf("\n");
                printf("\t");
            }
            if(i) printf(",\t");
            if(_Card->Squares[i].Name)
                printf("%s", _Card->Squares[i].Name);
            else 
                printf("XXXXXXXXXXXX");
        }
        printf("]\n");
    }
}



int main(int argc, char** argv)
{
    TLotoo_API Lotoo;
    if( LOTOO_API_VERSION != lotoo_init(&Lotoo)) {
        fprintf( stderr, "Lotoo version mismatch\n" );
        return 1;
    }

#   ifdef USE_CUSTOM_WIN32_ALLOC 
    TLotoo_PageAllocator Alloc;
    Alloc.UserData = 0;
    Alloc.PageSize = 4*1024;
    Alloc.AllocPages = &AllocPages;
    Alloc.FreePages = &FreePages;
    TLotoo_Context* Context = Lotoo.Context_Init(&Alloc);
#   else
    TLotoo_Context* Context = Lotoo.Context_Init(0);
#   endif

    TLotoo_Pack* LatestLoadedPack = 0;
    const char* ExePath = argv[0];
    TLotoo_Game* Game = 0;
    unsigned int Game_Index = 0;
    unsigned int Card_Index = 0;

    unsigned int arg_index = 1;
    printf("Lotoo CLI\n");
    while(1) {
        char request[1024];
        if (arg_index < argc) {
            strcpy_s(request, 1023, argv[arg_index]);
            arg_index++;
        } else {
            printf("?>");
            scanf_s("%s", request, 1023);
        }

        if(strcmp(request, "exit") == 0 ) {
            printf("< Exiting\n");
            break;
        } else if (IsPrefix("load", request)) {            
            TFileReader Reader;
            const char* FilePath = 0;
            if(IsPrefix("load ", request)) {
                FilePath = &request[5];
            } else {
                FilePath = "default.zip";
            }
            
            printf("< Loading pack \"%s\"\n", FilePath);
            Reader.File = fopen( FilePath, "rb"); 

            if(Reader.File) {
                TLotoo_PackLoader PackLoader;
                PackLoader.Read = &CliReadFile;
                PackLoader.UserData = (void*)&Reader;
                _fseeki64(Reader.File, 0, SEEK_END);
                PackLoader.TotalSize = _ftelli64(Reader.File);
                _fseeki64(Reader.File, 0, SEEK_SET);
                
                LatestLoadedPack = Lotoo.Context_LoadPack(Context, &PackLoader);
                if(LatestLoadedPack) {
                    printf("< Pack loaded (%d quizzes found)\n", Lotoo.Pack_Quizzes_GetCount( LatestLoadedPack) );
                }
                fclose(Reader.File);
            } else {
                printf("< Unable to load pack\n");
            }
        } else if (IsPrefix("card_next", request)) {
            if(!LatestLoadedPack) {
                printf("< load a pack to generate cards\n");
            } else if (!IsPrefix("card_next ", request)) {
                printf("< choose a type of card\n");
            } else {
                TLotoo_CardType Type;
                switch(request[10]) {
                    case '1': Type = ELotoo_CardType_OneLine1x5; break;
                    case '2': Type = ELotoo_CardType_USStyle5x5; break;
                    case '3': Type = ELotoo_CardType_EUStyle3x9; break;
                    default:  Type = -1; break;
                }
                printf("< generated card \n");
                TLotoo_Card Card;
                if( Lotoo.Pack_Card_Get(LatestLoadedPack, Type, Card_Index, &Card ) ) {
                    PrintCard(Type, &Card);
                    Card_Index++;
                } else {
                    printf("\tpack is invalid (maybe too small for such cards ?)\n");
                }
            }
        } else if (IsPrefix("game_start", request)) {
            if(Game) {
                printf("< game_start has already been called\n");
            } else if(!LatestLoadedPack) {
                printf("< load a pack before starting a game\n");
            } else {
                printf("< starting games with following pack\n");
                printf("\t[%d quizzes]\n", Lotoo.Pack_Quizzes_GetCount(LatestLoadedPack));
                Game = Lotoo.Game_Init(Context, LatestLoadedPack, ELotoo_CardType_OneLine1x5, rand());
            }
        } else if (IsPrefix("game_next", request)) {
            if(Game) {
                if(Game_Index < Lotoo.Game_Quizzes_GetCount(Game) ) {
                    TLotoo_Quizz Quizz;
                    Lotoo.Game_Quizzes_Get(Game, Game_Index, &Quizz);
                    printf("< Quizz [%d] %.*s->%s\n", Game_Index, Quizz.DataLen, Quizz.Data, Quizz.Name);
                } else {
                    printf("< Quizzes end reached\n");
                }
                Game_Index++;
            } else {
                printf("< Call game_start first\n");
            }
        } else if (IsPrefix("game_end", request)) {
            if(Game) {
                printf("< game_end \n");
                Lotoo.Game_Clean(Context, Game);
                Game = 0;
            } else {
                printf("< Call game_start first\n");
            }
        } else if (IsPrefix("game_test", request)) {
            const TLotoo_CardType Type = ELotoo_CardType_USStyle5x5;
            const unsigned int Card_Id = rand();

            TLotoo_Card Card;
            Lotoo.Pack_Card_Get(LatestLoadedPack, Type, Card_Id, &Card);
            printf("< [TEST] Watching card\n");
            PrintCard(Type, &Card);
            
            TLotoo_Game* Game = Lotoo.Game_Init(Context, LatestLoadedPack, Type, rand());
            printf("< [TEST] Start\n");

            unsigned int Game_Index = 0;
            while(1) {
                TLotoo_Quizz Quizz;
                if(!Lotoo.Game_Quizzes_Get(Game, Game_Index, &Quizz)) {
                    printf("< [TEST] Unexpected exit\n");
                    break;
                }
                printf("< [TEST] Quizz [%04d] %.*s\n", Game_Index, Quizz.DataLen, Quizz.Data);

                const TLotoo_CardStatus Status = Lotoo.Game_CheckCardStatus(Game, Game_Index, Card_Id);
                if(Status != ELotoo_CardStatus_Nothing) {
                    printf("< [TEST] BINGO ");
                    switch(Status) { 
                        case ELotoo_CardStatus_FullCard:         printf("FULL CARD");   break;
                        case ELotoo_CardStatus_OneLine:          printf("ONE LINE");    break;
                        case ELotoo_CardStatus_OneColumn:        printf("ONE COLUMN");  break;
                    }
                    printf(" !\n");
                    break;
                }
                Game_Index++;
            }
            printf("< [TEST] End\n");
            Lotoo.Game_Clean(Context, Game);
        } else {
            printf("< Unknown command\n");
        }
    }
    Lotoo.Context_Clean(Context);
    lotoo_clean(&Lotoo);
}