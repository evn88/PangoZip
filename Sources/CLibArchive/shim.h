#ifndef PANGOZIP_LIBARCHIVE_SHIM_H
#define PANGOZIP_LIBARCHIVE_SHIM_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <time.h>

/* Стабильный публичный ABI libarchive 3.x; macOS SDK содержит библиотеку без заголовков. */
struct archive;
struct archive_entry;
typedef ssize_t archive_read_callback(struct archive *, void *, const void **);
typedef int64_t archive_skip_callback(struct archive *, void *, int64_t);
typedef int64_t archive_seek_callback(struct archive *, void *, int64_t, int);
typedef int archive_open_callback(struct archive *, void *);
typedef int archive_close_callback(struct archive *, void *);
struct archive *archive_read_new(void);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_filter_lzma(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_set_seek_callback(struct archive *, archive_seek_callback *);
int archive_read_open2(struct archive *, void *, archive_open_callback *, archive_read_callback *, archive_skip_callback *, archive_close_callback *);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_format_name(struct archive *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
long archive_entry_mtime_nsec(struct archive_entry *);
int archive_entry_birthtime_is_set(struct archive_entry *);
time_t archive_entry_birthtime(struct archive_entry *);
long archive_entry_birthtime_nsec(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
#endif
