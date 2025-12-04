//
//  RGB2GIF-Bridging-Header.h
//  RGB2GIF
//
//  Bridging header for Rust FFI
//

#ifndef RGB2GIF_Bridging_Header_h
#define RGB2GIF_Bridging_Header_h

// Import generated UniFFI header for Rust bindings if present.
// This allows Swift-only builds to succeed before Rust artifacts exist.
#if __has_include("Bridge/Generated/rgb2gif_processorFFI.h")
#import "Bridge/Generated/rgb2gif_processorFFI.h"
#elif __has_include("rgb2gif_processorFFI.h")
#import "rgb2gif_processorFFI.h"
#endif

// If you also generate a cbindgen header like yingif_ffi.h, include it conditionally too.
#if __has_include("Bridge/Generated/yingif_ffi.h")
#import "Bridge/Generated/yingif_ffi.h"
#elif __has_include("yingif_ffi.h")
#import "yingif_ffi.h"
#endif

#endif /* RGB2GIF_Bridging_Header_h */
