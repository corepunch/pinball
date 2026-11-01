//
//  PBPlatform.h
//  The small UIKit/AppKit differences, in one place. Same approach as the common
//  code in Apple's Fox sample: a typedef for shared types, no #ifs in game code.
//

#import <TargetConditionals.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
typedef UIBezierPath PBBezierPath;
#define PBBezierLineTo(path, point) [(path) addLineToPoint:(point)]
#else
#import <AppKit/AppKit.h>
typedef NSBezierPath PBBezierPath;
#define PBBezierLineTo(path, point) [(path) lineToPoint:(point)]
#endif
