typedef struct SLotoo_Context TLotoo_Context;
typedef struct SLotoo_Game TLotoo_Game;
typedef struct SLotoo_Pack TLotoo_Pack;

typedef unsigned char TLotoo_Bool;
typedef unsigned long long int TLotoo_PackId;
typedef char* TLotoo_StringUTF8Z;
typedef unsigned char* TLotoo_Data;
typedef unsigned int TLotoo_DataLen;
typedef unsigned int TLotoo_Index;
typedef unsigned int TLotoo_Seed;

typedef struct SLotoo_Quizz {
    TLotoo_StringUTF8Z  Name;
    TLotoo_Data         Data;
    TLotoo_DataLen      DataLen;
} TLotoo_Quizz;

typedef struct SLotoo_Square {
    TLotoo_StringUTF8Z  Name; // Null for free squares
} TLotoo_Square;

typedef struct SLotoo_Card {
    TLotoo_Square  Squares[27];
} TLotoo_Card;

typedef enum ELotoo_CardType {
    ELotoo_CardType_USStyle5x5,
    ELotoo_CardType_EUStyle3x9,
    ELotoo_CardType_OneLine1x5,
} TLotoo_CardType;

typedef enum ELotoo_CardStatus {
    ELotoo_CardStatus_Nothing,
    ELotoo_CardStatus_OneLine,
    ELotoo_CardStatus_OneColumn,
    ELotoo_CardStatus_FullCard,
} TLotoo_CardStatus;

typedef struct SLotoo_PackLoader {
    void* UserData;
    unsigned int (*Read)(void* _UserData, unsigned long long offset, unsigned char* _Buffer, unsigned int _BufferSize);
    unsigned int TotalSize;
} TLotoo_PackLoader;

typedef struct SLotoo_PageAllocator {
    void* UserData;
    unsigned long long PageSize;
    void* (*AllocPages)(void* _UserData, unsigned long long _Size);
    void  (*FreePages)(void* _UserData, void* _Ptr);
} TLotoo_PageAllocator;

typedef struct SLotoo_API {
    TLotoo_Context*         (*Context_Init)                     (TLotoo_PageAllocator* _CustomPageAllocator);
    TLotoo_Pack*            (*Context_LoadPack)                 (TLotoo_Context* _Context, TLotoo_PackLoader* _PackLoader);
    void                    (*Context_Clean)                    (TLotoo_Context* _Context);

    TLotoo_PackId           (*Pack_Id_Get)                      (TLotoo_Pack* _Pack);
    TLotoo_Index            (*Pack_Quizzes_GetCount)            (TLotoo_Pack* _Pack);
    TLotoo_Bool             (*Pack_Quizzes_Get)                 (TLotoo_Pack* _Pack, TLotoo_Index _QuizzIndex, TLotoo_Quizz* _Quizz);
    TLotoo_Bool             (*Pack_Card_Get)                    (TLotoo_Pack* _Pack, TLotoo_CardType _CardType, TLotoo_Index _CardIndex, TLotoo_Card* _Card);
    
    TLotoo_Game*            (*Game_Init)                        (TLotoo_Context* _Context, TLotoo_Pack* _Pack, TLotoo_CardType _CardType, TLotoo_Seed _Seed);
    TLotoo_Index            (*Game_Quizzes_GetCount)            (TLotoo_Game* _Game);
    TLotoo_Bool             (*Game_Quizzes_Get)                 (TLotoo_Game* _Game, TLotoo_Index _Index, TLotoo_Quizz* _Quizz);
    TLotoo_CardStatus       (*Game_CheckCardStatus)             (TLotoo_Game* _Game, TLotoo_Index _LatestQuizzIndex, TLotoo_Index _CardIndex);
    void                    (*Game_Clean)                       (TLotoo_Context* _Context, TLotoo_Game* _Game);
} TLotoo_API;

enum { LOTOO_API_VERSION = 0 };
unsigned int                lotoo_init(TLotoo_API* _API);
void                        lotoo_clean(TLotoo_API* _API);
