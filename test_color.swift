import Foundation
import CVTerm

func test() {
    var cell = VTermScreenCell()
    var fg = cell.fg
//  vterm_screen_convert_color_to_rgb(nil, &fg)
    print(fg.rgb.red)
}
