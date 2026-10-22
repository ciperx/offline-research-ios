/*
 * Minimal SQLite3 declarations for the Linux type-check harness.
 *
 * NOT used by the iOS build: iOS/macOS ship <sqlite3.h> in the SDK, and the app links
 * libsqlite3.tbd via `import SQLite3`. This file exists only so Scripts/dev/verify_core.sh
 * can compile App/Sources/Retrieval/CorpusStore.swift on a machine without the SQLite
 * development headers. Only the symbols CorpusStore touches are declared.
 */
#ifndef OFFLINE_RESEARCH_SQLITE3_SHIM_H
#define OFFLINE_RESEARCH_SQLITE3_SHIM_H

#include <stdint.h>

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef void (*sqlite3_destructor_type)(void *);

#define SQLITE_OK            0
#define SQLITE_ROW         100
#define SQLITE_DONE        101
#define SQLITE_OPEN_READONLY 0x00000001
#define SQLITE_OPEN_READWRITE 0x00000002
#define SQLITE_OPEN_CREATE  0x00000004
#define SQLITE_OPEN_NOMUTEX 0x00008000

int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close(sqlite3 *db);
const char *sqlite3_errmsg(sqlite3 *db);
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_finalize(sqlite3_stmt *pStmt);
int sqlite3_bind_text(sqlite3_stmt *pStmt, int i, const char *zData, int nData, sqlite3_destructor_type destroy);
int sqlite3_bind_int(sqlite3_stmt *pStmt, int i, int v);
int sqlite3_bind_int64(sqlite3_stmt *pStmt, int i, int64_t v);
int sqlite3_step(sqlite3_stmt *pStmt);
int64_t sqlite3_column_int64(sqlite3_stmt *pStmt, int i);
double sqlite3_column_double(sqlite3_stmt *pStmt, int i);
const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int i);

#endif
