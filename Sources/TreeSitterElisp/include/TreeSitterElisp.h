#ifndef TreeSitterElisp_h
#define TreeSitterElisp_h

typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_elisp(void);

#ifdef __cplusplus
}
#endif

#endif
