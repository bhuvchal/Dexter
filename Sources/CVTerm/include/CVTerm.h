#ifndef CVTerm_h
#define CVTerm_h

#include "PTYManager.h"
#include <vterm.h>

void cvterm_set_palette_rgb(VTermState *state, int index, uint8_t r, uint8_t g,
                            uint8_t b);

#endif /* CVTerm_h */
