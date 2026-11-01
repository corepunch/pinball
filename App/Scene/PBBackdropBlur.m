#import "PBBackdropBlur.h"

// Compiled at run time, as SceneKit's shader modifiers are, so building needs no Metal toolchain.
static NSString *const kPBBlurShaders =
    @"#include <metal_stdlib>\n"
    @"using namespace metal;\n"
    @"\n"
    @"struct PBBlurIn { float4 position [[attribute(0)]]; };\n"
    @"struct PBBlurOut { float4 position [[position]]; float2 uv; };\n"
    @"\n"
    @"vertex PBBlurOut pbBlurVertex(PBBlurIn in [[stage_in]]) {\n"
    @"    PBBlurOut out;\n"
    @"    out.position = float4(in.position.xy, 0, 1);\n"
    @"    out.uv = float2((in.position.x + 1) * .5, 1 - (in.position.y + 1) * .5);\n"
    @"    return out;\n"
    @"}\n"
    @"\n"
    @"constexpr sampler pbBlurSampler(coord::normalized, filter::linear, address::clamp_to_edge);\n"
    @"\n"
    @"static float4 pbBlur(texture2d<float> image, float2 uv, float2 direction) {\n"
    @"    const float weights[7] = { .1964, .1747, .1210, .0660, .0280, .0092, .0024 };\n"
    @"    float2 step = direction * 1.6 / float2(image.get_width(), image.get_height());\n"
    @"    float4 sum = image.sample(pbBlurSampler, uv) * weights[0];\n"
    @"    for (int i = 1; i < 7; i++) {\n"
    @"        sum += image.sample(pbBlurSampler, uv + step * float(i)) * weights[i];\n"
    @"        sum += image.sample(pbBlurSampler, uv - step * float(i)) * weights[i];\n"
    @"    }\n"
    @"    return sum;\n"
    @"}\n"
    @"\n"
    @"fragment float4 pbBlurAcross(PBBlurOut in [[stage_in]], texture2d<float> colorSampler [[texture(0)]]) {\n"
    @"    return pbBlur(colorSampler, in.uv, float2(1, 0));\n"
    @"}\n"
    @"\n"
    @"fragment float4 pbBlurAlong(PBBlurOut in [[stage_in]], texture2d<float> colorSampler [[texture(0)]]) {\n"
    @"    return pbBlur(colorSampler, in.uv, float2(0, 1));\n"
    @"}\n"
    @"\n"
    @"fragment float4 pbBlurShow(PBBlurOut in [[stage_in]], texture2d<float> colorSampler [[texture(0)]]) {\n"
    @"    return colorSampler.sample(pbBlurSampler, in.uv);\n"
    @"}\n";

@implementation PBBackdropBlur

+ (SCNTechnique *)techniqueForDevice:(id<MTLDevice>)device {
    NSError *error;
    id<MTLLibrary> library = [device newLibraryWithSource:kPBBlurShaders options:nil error:&error];
    if (!library) { NSLog(@"Could not build the blur: %@", error); return nil; }
    NSDictionary *(^pass)(NSString *, NSString *, NSString *) = ^(NSString *from, NSString *to, NSString *shader) {
        return @{ @"draw": @"DRAW_QUAD", @"metalVertexShader": @"pbBlurVertex", @"metalFragmentShader": shader,
                  @"inputs": @{ @"colorSampler": from }, @"outputs": @{ @"color": to } };
    };
    // Blurred small, for a wide blur at little cost: the game is paused, but still drawing.
    // Halved twice on the way down, so a bright star averages out rather than flickering through.
    NSDictionary *small = @{ @"type": @"color", @"scaleFactor": @0.25 };
    SCNTechnique *technique = [SCNTechnique techniqueWithDictionary:@{
        @"sequence": @[ @"scene", @"half", @"quarter", @"across", @"along", @"show" ],
        @"targets": @{ @"sharp": @{ @"type": @"color" }, @"halved": @{ @"type": @"color", @"scaleFactor": @0.5 }, @"small": small, @"first": small, @"second": small },
        @"passes": @{
            @"scene": @{ @"draw": @"DRAW_SCENE", @"outputs": @{ @"color": @"sharp" } },
            @"half": pass(@"sharp", @"halved", @"pbBlurShow"),
            @"quarter": pass(@"halved", @"small", @"pbBlurShow"),
            @"across": pass(@"small", @"first", @"pbBlurAcross"),
            @"along": pass(@"first", @"second", @"pbBlurAlong"),
            @"show": pass(@"second", @"COLOR", @"pbBlurShow"),
        },
    }];
    technique.library = library;
    return technique;
}

@end
