#include "DjVuBridge.h"
#include <libdjvu/ddjvuapi.h>
#include <libdjvu/miniexp.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *title;
    int page;
    int level;
} PDVBookmark;

struct PDVDjVuDocument {
    ddjvu_context_t *context;
    ddjvu_document_t *document;
    pthread_mutex_t mutex;
    PDVBookmark *bookmarks;
    int bookmark_count;
};

static void pdv_messages(PDVDjVuDocument *value, int wait) {
    if (wait) ddjvu_message_wait(value->context);
    while (ddjvu_message_peek(value->context)) ddjvu_message_pop(value->context);
}

static int pdv_page_info_locked(PDVDjVuDocument *value, int index,
                                ddjvu_pageinfo_t *info) {
    ddjvu_status_t status;
    do {
        status = ddjvu_document_get_pageinfo(value->document, index, info);
        if (status < DDJVU_JOB_OK) pdv_messages(value, 1);
    } while (status < DDJVU_JOB_OK);
    return status == DDJVU_JOB_OK && info->width > 0 && info->height > 0;
}

static void pdv_append_bookmark(PDVDjVuDocument *value, miniexp_t item, int level) {
    miniexp_t title = miniexp_nth(0, item);
    miniexp_t target = miniexp_nth(1, item);
    if (!miniexp_stringp(title) || !miniexp_stringp(target)) return;
    const char *destination = miniexp_to_str(target);
    int page = destination[0] == '#' ? atoi(destination + 1) - 1
                                     : ddjvu_document_search_pageno(value->document, destination);
    if (page >= 0 && page < ddjvu_document_get_pagenum(value->document)) {
        PDVBookmark *grown = realloc(value->bookmarks,
                                     (size_t)(value->bookmark_count + 1) * sizeof(PDVBookmark));
        if (!grown) return;
        value->bookmarks = grown;
        PDVBookmark *entry = &value->bookmarks[value->bookmark_count++];
        entry->title = strdup(miniexp_to_str(title));
        entry->page = page;
        entry->level = level;
    }
    for (miniexp_t child = miniexp_cdr(miniexp_cdr(item));
         child != miniexp_nil; child = miniexp_cdr(child)) {
        pdv_append_bookmark(value, miniexp_car(child), level + 1);
    }
}

PDVDjVuDocument *pdv_djvu_open(const char *utf8_path) {
    if (!utf8_path) return NULL;
    PDVDjVuDocument *value = calloc(1, sizeof(PDVDjVuDocument));
    if (!value) return NULL;
    pthread_mutex_init(&value->mutex, NULL);
    value->context = ddjvu_context_create("pdf-viewer");
    if (!value->context) { pdv_djvu_close(value); return NULL; }
    value->document = ddjvu_document_create_by_filename_utf8(value->context, utf8_path, 1);
    if (!value->document) { pdv_djvu_close(value); return NULL; }
    ddjvu_job_t *job = ddjvu_document_job(value->document);
    while (!ddjvu_job_done(job)) pdv_messages(value, 1);
    pdv_messages(value, 0);
    if (ddjvu_job_error(job) || ddjvu_document_get_pagenum(value->document) <= 0) {
        pdv_djvu_close(value);
        return NULL;
    }
    miniexp_t outline;
    while ((outline = ddjvu_document_get_outline(value->document)) == miniexp_dummy)
        pdv_messages(value, 1);
    if (miniexp_length(outline) > 1) {
        for (miniexp_t item = miniexp_cdr(outline); item != miniexp_nil;
             item = miniexp_cdr(item)) {
            pdv_append_bookmark(value, miniexp_car(item), 0);
        }
    }
    ddjvu_miniexp_release(value->document, outline);
    return value;
}

void pdv_djvu_close(PDVDjVuDocument *value) {
    if (!value) return;
    pthread_mutex_lock(&value->mutex);
    for (int i = 0; i < value->bookmark_count; i++) free(value->bookmarks[i].title);
    free(value->bookmarks);
    if (value->document) ddjvu_document_release(value->document);
    if (value->context) ddjvu_context_release(value->context);
    pthread_mutex_unlock(&value->mutex);
    pthread_mutex_destroy(&value->mutex);
    free(value);
}

int pdv_djvu_page_count(PDVDjVuDocument *value) {
    return value ? ddjvu_document_get_pagenum(value->document) : 0;
}

int pdv_djvu_page_info(PDVDjVuDocument *value, int index,
                       int *width, int *height, int *dpi) {
    if (!value || index < 0 || index >= pdv_djvu_page_count(value)) return 0;
    pthread_mutex_lock(&value->mutex);
    ddjvu_pageinfo_t info = {0};
    int okay = pdv_page_info_locked(value, index, &info);
    if (okay) {
        int quarter_turn = info.rotation == 1 || info.rotation == 3;
        *width = quarter_turn ? info.height : info.width;
        *height = quarter_turn ? info.width : info.height;
        *dpi = info.dpi > 0 ? info.dpi : 300;
    }
    pthread_mutex_unlock(&value->mutex);
    return okay;
}

int pdv_djvu_render(PDVDjVuDocument *value, int index, int target_width,
                    unsigned char **rgb, int *width, int *height) {
    if (!value || index < 0 || index >= pdv_djvu_page_count(value) ||
        target_width < 1 || !rgb || !width || !height) return 0;
    *rgb = NULL;
    pthread_mutex_lock(&value->mutex);
    ddjvu_page_t *page = ddjvu_page_create_by_pageno(value->document, index);
    if (!page) { pthread_mutex_unlock(&value->mutex); return 0; }
    while (!ddjvu_page_decoding_done(page)) pdv_messages(value, 1);
    pdv_messages(value, 0);
    int source_width = ddjvu_page_get_width(page);
    int source_height = ddjvu_page_get_height(page);
    int okay = !ddjvu_page_decoding_error(page) && source_width > 0 && source_height > 0;
    if (okay) {
        int w = target_width < source_width ? target_width : source_width;
        if (w > 8192) w = 8192;
        double aspect = (double)source_height / source_width;
        if ((double)w * aspect > 8192) w = (int)(8192 / aspect);
        if ((double)w * w * aspect > 30000000) w = (int)sqrt(30000000 / aspect);
        if (w < 1) w = 1;
        int h = (int)((double)source_height * w / source_width + 0.5);
        if (h < 1 || h > 8192 || (size_t)w * h > 30000000) okay = 0;
        if (okay) {
            unsigned char *pixels = malloc((size_t)w * h * 3);
            ddjvu_format_t *format = ddjvu_format_create(DDJVU_FORMAT_RGB24, 0, NULL);
            if (!pixels || !format) okay = 0;
            if (okay) {
                ddjvu_format_set_row_order(format, 1);
                ddjvu_rect_t rect = {0, 0, (unsigned int)w, (unsigned int)h};
                okay = ddjvu_page_render(page, DDJVU_RENDER_COLOR, &rect, &rect,
                                         format, (unsigned long)w * 3, (char *)pixels);
            }
            if (format) ddjvu_format_release(format);
            if (okay) { *rgb = pixels; *width = w; *height = h; }
            else free(pixels);
        }
    }
    ddjvu_page_release(page);
    pthread_mutex_unlock(&value->mutex);
    return okay;
}

int pdv_djvu_bookmark_count(PDVDjVuDocument *value) {
    return value ? value->bookmark_count : 0;
}

const char *pdv_djvu_bookmark_title(PDVDjVuDocument *value, int index) {
    return value && index >= 0 && index < value->bookmark_count
        ? value->bookmarks[index].title : NULL;
}

int pdv_djvu_bookmark_page(PDVDjVuDocument *value, int index) {
    return value && index >= 0 && index < value->bookmark_count
        ? value->bookmarks[index].page : -1;
}

int pdv_djvu_bookmark_level(PDVDjVuDocument *value, int index) {
    return value && index >= 0 && index < value->bookmark_count
        ? value->bookmarks[index].level : -1;
}

static void pdv_collect_text(miniexp_t node, char **text, size_t *length, size_t *capacity) {
    if (miniexp_stringp(node)) {
        const char *part = miniexp_to_str(node);
        size_t count = strlen(part);
        if (*length + count + 2 > *capacity) {
            size_t needed = (*length + count + 2) * 2;
            char *grown = realloc(*text, needed);
            if (!grown) return;
            *text = grown;
            *capacity = needed;
        }
        memcpy(*text + *length, part, count);
        *length += count;
        (*text)[(*length)++] = ' ';
        (*text)[*length] = '\0';
    } else if (miniexp_consp(node)) {
        for (miniexp_t item = node; item != miniexp_nil; item = miniexp_cdr(item))
            pdv_collect_text(miniexp_car(item), text, length, capacity);
    }
}

char *pdv_djvu_page_text(PDVDjVuDocument *value, int index) {
    if (!value || index < 0 || index >= pdv_djvu_page_count(value)) return NULL;
    pthread_mutex_lock(&value->mutex);
    miniexp_t expression;
    while ((expression = ddjvu_document_get_pagetext(value->document, index, "line")) == miniexp_dummy)
        pdv_messages(value, 1);
    char *text = calloc(1, 1);
    size_t length = 0, capacity = 1;
    if (miniexp_consp(expression)) pdv_collect_text(expression, &text, &length, &capacity);
    ddjvu_miniexp_release(value->document, expression);
    pthread_mutex_unlock(&value->mutex);
    return text;
}

void pdv_djvu_free(void *pointer) { free(pointer); }
