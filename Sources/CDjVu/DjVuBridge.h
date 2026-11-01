#ifndef PDF_VIEWER_DJVU_BRIDGE_H
#define PDF_VIEWER_DJVU_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PDVDjVuDocument PDVDjVuDocument;

PDVDjVuDocument *pdv_djvu_open(const char *utf8_path);
void pdv_djvu_close(PDVDjVuDocument *document);
int pdv_djvu_page_count(PDVDjVuDocument *document);
int pdv_djvu_page_info(PDVDjVuDocument *document, int page_index,
                       int *width, int *height, int *dpi);
int pdv_djvu_render(PDVDjVuDocument *document, int page_index, int target_width,
                    unsigned char **rgb, int *width, int *height);
int pdv_djvu_bookmark_count(PDVDjVuDocument *document);
const char *pdv_djvu_bookmark_title(PDVDjVuDocument *document, int index);
int pdv_djvu_bookmark_page(PDVDjVuDocument *document, int index);
int pdv_djvu_bookmark_level(PDVDjVuDocument *document, int index);
char *pdv_djvu_page_text(PDVDjVuDocument *document, int page_index);
void pdv_djvu_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
