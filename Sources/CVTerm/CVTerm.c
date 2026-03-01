#include <vterm.h>

void cvterm_set_palette_rgb(VTermState *state, int index, uint8_t r, uint8_t g,
                            uint8_t b) {
  VTermColor col;
  col.type = 0; // VTERM_COLOR_RGB
  col.rgb.red = r;
  col.rgb.green = g;
  col.rgb.blue = b;
  vterm_state_set_palette_color(state, index, &col);
}
