#import "LiquidGlassSwitch.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreVideo/CoreVideo.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>

#pragma mark - 1. Metal Shader Source
static NSString *LGGlassMetalSource(void) {
    return @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Uniforms {\n"
    "    float2 resolution;\n"
    "    float2 screenResolution;\n"
    "    float2 cardOrigin;\n"
    "    float2 wallpaperResolution;\n"
    "    float  radius;\n"
    "    float  bezelWidth;\n"
    "    float  glassThickness;\n"
    "    float  refractionScale;\n"
    "    float  refractiveIndex;\n"
    "    float  specularOpacity;\n"
    "    float  specularAngle;\n"
    "    float  blur;\n"
    "    float2 wallpaperOrigin;\n"
    "    float  samplingOrientation;\n"
    "    float  hasShapeMask;\n"
    "};\n"
    "float surfaceConvexSquircle(float x) { return pow(1.0 - pow(1.0 - x, 4.0), 0.25); }\n"
    "float2 refractRay(float2 normal, float eta) {\n"
    "    float cosI = -normal.y;\n"
    "    float k    = 1.0 - eta * eta * (1.0 - cosI * cosI);\n"
    "    if (k < 0.0) return float2(0.0);\n"
    "    float kSqrt = sqrt(k);\n"
    "    return float2(-(eta * cosI + kSqrt) * normal.x, eta - (eta * cosI + kSqrt) * normal.y);\n"
    "}\n"
    "float rawRefraction(float bezelRatio, float glassThickness, float bezelWidth, float eta) {\n"
    "    float x     = clamp(bezelRatio, 0.05, 0.95);\n"
    "    float y     = surfaceConvexSquircle(x);\n"
    "    float y2    = surfaceConvexSquircle(x + 0.001);\n"
    "    float deriv = (y2 - y) / 0.001;\n"
    "    float mag   = sqrt(deriv * deriv + 1.0);\n"
    "    float2 n    = float2(-deriv / mag, -1.0 / mag);\n"
    "    float2 r    = refractRay(n, eta);\n"
    "    if (length(r) < 0.0001 || abs(r.y) < 0.0001) return 0.0;\n"
    "    float remaining = y * bezelWidth + glassThickness;\n"
    "    return r.x * (remaining / r.y);\n"
    "}\n"
    "float displacementAtRatio(float bezelRatio, float glassThickness, float bezelWidth, float eta) {\n"
    "    float peak = rawRefraction(0.05, glassThickness, bezelWidth, eta);\n"
    "    if (abs(peak) < 0.0001) return 0.0;\n"
    "    float raw     = rawRefraction(bezelRatio, glassThickness, bezelWidth, eta);\n"
    "    float norm    = raw / peak;\n"
    "    float falloff = 1.0 - smoothstep(0.0, 1.0, bezelRatio);\n"
    "    return norm * falloff;\n"
    "}\n"
    "float linearizeSRGB(float c) { return c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92; }\n"
    "float gammaCorrectSRGB(float c) { return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055; }\n"
    "float3 srgbToXyz(float3 rgb) { float3 lin = float3(linearizeSRGB(rgb.r), linearizeSRGB(rgb.g), linearizeSRGB(rgb.b)); return float3(dot(lin, float3(0.4124, 0.3576, 0.1805)), dot(lin, float3(0.2126, 0.7152, 0.0722)), dot(lin, float3(0.0193, 0.1192, 0.9505))); }\n"
    "float3 xyzToSrgb(float3 xyz) { float3 lin = float3(dot(xyz, float3( 3.2406, -1.5372, -0.4986)), dot(xyz, float3(-0.9689,  1.8758,  0.0415)), dot(xyz, float3( 0.0557, -0.2040,  1.0570))); return clamp(float3(gammaCorrectSRGB(lin.r), gammaCorrectSRGB(lin.g), gammaCorrectSRGB(lin.b)), 0.0, 1.0); }\n"
    "float labF(float t) { return t > 0.00885645167 ? pow(t, 1.0 / 3.0) : (7.787037 * t + 16.0 / 116.0); }\n"
    "float labInvF(float t) { float t3 = t * t * t; return t3 > 0.00885645167 ? t3 : (t - 16.0 / 116.0) / 7.787037; }\n"
    "float3 xyzToLab(float3 xyz) { float3 n = xyz / float3(0.95047, 1.0, 1.08883); float fx = labF(n.x), fy = labF(n.y), fz = labF(n.z); return float3(116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)); }\n"
    "float3 labToXyz(float3 lab) { float fy = (lab.x + 16.0) / 116.0; float fx = fy + lab.y / 500.0; float fz = fy - lab.z / 200.0; return float3(0.95047 * labInvF(fx), labInvF(fy), 1.08883 * labInvF(fz)); }\n"
    "float3 srgbToLch(float3 rgb) { float3 lab = xyzToLab(srgbToXyz(rgb)); return float3(lab.x, length(lab.yz), atan2(lab.z, lab.y)); }\n"
    "float3 lchToSrgb(float3 lch) { float3 lab = float3(lch.x, cos(lch.z) * lch.y, sin(lch.z) * lch.y); return xyzToSrgb(labToXyz(lab)); }\n"
    "struct VertexOut { float4 position [[position]]; float2 localUV; };\n"
    "vertex VertexOut vertexShader(uint vid [[vertex_id]]) {\n"
    "    float2 pos[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1, 1), float2(1,-1), float2(1, 1) };\n"
    "    float2 uv[6] = { float2(0,1), float2(1,1), float2(0,0), float2(0,0), float2(1,1), float2(1,0) };\n"
    "    VertexOut out; out.position = float4(pos[vid], 0, 1); out.localUV = uv[vid]; return out;\n"
    "}\n"
    "fragment float4 fragmentShader(VertexOut in [[stage_in]], texture2d<float> blurredTex [[texture(0)]], constant Uniforms& u [[buffer(0)]]) {\n"
    "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "    float2 px = in.localUV * u.resolution;\n"
    "    float W = u.resolution.x, H = u.resolution.y;\n"
    "    float R = u.radius, bezel = u.bezelWidth;\n"
    "    float eta = 1.0 / u.refractiveIndex;\n"
    "    bool inLeft = px.x < R, inRight = px.x > W - R;\n"
    "    bool inTop = px.y < R, inBottom = px.y > H - R;\n"
    "    bool inCorner = (inLeft || inRight) && (inTop || inBottom);\n"
    "    float cx = inLeft ? px.x - R : inRight ? px.x - (W - R) : 0.0;\n"
    "    float cy = inTop ? px.y - R : inBottom ? px.y - (H - R) : 0.0;\n"
    "    float distFromCenter = length(float2(cx, cy));\n"
    "    if (inCorner && distFromCenter > R + 1.0) discard_fragment();\n"
    "    float distFromSide;\n"
    "    float2 dir;\n"
    "    if (inCorner) {\n"
    "        distFromSide = max(0.0, R - distFromCenter);\n"
    "        dir = distFromCenter > 0.001 ? normalize(float2(cx, cy)) : float2(0);\n"
    "    } else {\n"
    "        float dL = px.x, dR = W - px.x, dT = px.y, dB = H - px.y;\n"
    "        float dMin = min(min(dL, dR), min(dT, dB));\n"
    "        distFromSide = dMin;\n"
    "        dir = float2((dL < dR && dL == dMin) ? -1.0 : (dR <= dL && dR == dMin) ? 1.0 : 0.0, (dT < dB && dT == dMin) ? -1.0 : (dB <= dT && dB == dMin) ? 1.0 : 0.0);\n"
    "    }\n"
    "    float edgeOpacity = inCorner ? clamp(1.0 - max(0.0, distFromCenter - R), 0.0, 1.0) : 1.0;\n"
    "    float bezelRatio = clamp(distFromSide / bezel, 0.0, 1.0);\n"
    "    float normDisp = distFromSide < bezel ? displacementAtRatio(bezelRatio, u.glassThickness, bezel, eta) : 0.0;\n"
    "    float2 dispPx = -dir * normDisp * bezel * u.refractionScale * edgeOpacity;\n"
    "    float2 screenPx = u.cardOrigin + px + dispPx;\n"
    "    float2 sampleUV = clamp((screenPx - u.wallpaperOrigin) / u.wallpaperResolution, 0.0, 1.0);\n"
    "    float4 bgColor = blurredTex.sample(s, sampleUV);\n"
    "    float2 prismOffset = dispPx / max(u.wallpaperResolution, float2(1.0));\n"
    "    float dispersion = clamp(length(prismOffset) * 24.0, 0.0, 0.012);\n"
    "    float2 redUV = clamp(sampleUV - prismOffset * 0.55, 0.0, 1.0);\n"
    "    float2 blueUV = clamp(sampleUV + prismOffset * 0.55, 0.0, 1.0);\n"
    "    float3 dispersed = float3(blurredTex.sample(s, mix(sampleUV, redUV, dispersion * 80.0)).r, bgColor.g, blurredTex.sample(s, mix(sampleUV, blueUV, dispersion * 80.0)).b);\n"
    "    bgColor.rgb = mix(bgColor.rgb, dispersed, dispersion * 0.65);\n"
    "    float2 lightDir = float2(cos(u.specularAngle), -sin(u.specularAngle));\n"
    "    float specDot = dot(dir, lightDir);\n"
    "    float strokeMask = clamp(1.0 - (distFromSide / 2.0), 0.0, 1.0);\n"
    "    float lobeStart = 0.66, lobeWidth = 0.20;\n"
    "    float primary = smoothstep(lobeStart, lobeStart + lobeWidth, specDot);\n"
    "    float secondary = smoothstep(lobeStart, lobeStart + lobeWidth, -specDot);\n"
    "    float cornerSpec = smoothstep(0.46, 0.90, abs(specDot));\n"
    "    float specLobe = inCorner ? cornerSpec : (primary + secondary);\n"
    "    float fresnel = pow(clamp(1.0 - bezelRatio, 0.0, 1.0), 2.2) * edgeOpacity;\n"
    "    float specular = specLobe * strokeMask * u.specularOpacity * 2.15 * edgeOpacity;\n"
    "    float highlight = specular + fresnel * 0.34;\n"
    "    float3 lch = srgbToLch(clamp(bgColor.rgb, 0.0, 1.0));\n"
    "    lch.x = clamp(lch.x + highlight * 36.0, 0.0, 100.0);\n"
    "    lch.y = max(0.0, lch.y - highlight * 9.0);\n"
    "    bgColor.rgb = mix(bgColor.rgb, lchToSrgb(lch), clamp(highlight * 0.70, 0.0, 1.0));\n"
    "    return float4(bgColor.rgb, edgeOpacity);\n"
    "}\n";
}

#pragma mark - 2. Engine Globals & Setup
static id<MTLDevice> sDevice;
static id<MTLRenderPipelineState> sPipeline;
static id<MTLCommandQueue> sCommandQueue;

static CGColorSpaceRef LGSharedRGBColorSpace(void) {
    static CGColorSpaceRef sColorSpace = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sColorSpace = CGColorSpaceCreateDeviceRGB(); });
    return sColorSpace;
}

static void LGEnsureSharedGlassPipelinesReady(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sDevice = MTLCreateSystemDefaultDevice();
        id<MTLLibrary> lib = [sDevice newLibraryWithSource:LGGlassMetalSource() options:nil error:nil];
        id<MTLFunction> vertex = [lib newFunctionWithName:@"vertexShader"];
        id<MTLFunction> fragment = [lib newFunctionWithName:@"fragmentShader"];
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
        color.pixelFormat = MTLPixelFormatBGRA8Unorm;
        color.blendingEnabled = YES;
        color.rgbBlendOperation = MTLBlendOperationAdd;
        color.alphaBlendOperation = MTLBlendOperationAdd;
        color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        color.sourceAlphaBlendFactor = MTLBlendFactorOne;
        color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        sPipeline = [sDevice newRenderPipelineStateWithDescriptor:descriptor error:nil];
        sCommandQueue = [sDevice newCommandQueue];
    });
}

#pragma mark - 3. ZeroCopyBridge
@interface LGZeroCopyBridge : NSObject
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) CVMetalTextureRef cvTexture;
- (BOOL)setupBufferWithWidth:(size_t)width height:(size_t)height;
- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions;
- (size_t)bufferWidth;
- (size_t)bufferHeight;
@end

@implementation LGZeroCopyBridge
- (instancetype)init {
    self = [super init];
    if (self) {
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, sDevice, nil, &_textureCache);
    }
    return self;
}
- (void)dealloc {
    if (_cvTexture) CFRelease(_cvTexture);
    if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
    if (_textureCache) CFRelease(_textureCache);
}
- (size_t)bufferWidth {
    return _pixelBuffer ? CVPixelBufferGetWidth(_pixelBuffer) : 0;
}
- (size_t)bufferHeight {
    return _pixelBuffer ? CVPixelBufferGetHeight(_pixelBuffer) : 0;
}
- (BOOL)setupBufferWithWidth:(size_t)width height:(size_t)height {
    if (_cvTexture) { CFRelease(_cvTexture); _cvTexture = NULL; }
    if (_pixelBuffer) { CVPixelBufferRelease(_pixelBuffer); _pixelBuffer = NULL; }
    NSDictionary *attrs = @{ (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
                             (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
                             (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &_pixelBuffer);
    if (status != kCVReturnSuccess || !_pixelBuffer) return NO;
    status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, _pixelBuffer, nil, MTLPixelFormatBGRA8Unorm, width, height, 0, &_cvTexture);
    return (status == kCVReturnSuccess && _cvTexture);
}
- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions {
    if (!_pixelBuffer) return nil;
    CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
    void *data = CVPixelBufferGetBaseAddress(_pixelBuffer);
    size_t width = CVPixelBufferGetWidth(_pixelBuffer);
    size_t height = CVPixelBufferGetHeight(_pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(_pixelBuffer);
    CGContextRef context = CGBitmapContextCreate(data, width, height, 8, bytesPerRow, LGSharedRGBColorSpace(), kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (actions) actions(context);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
    CVMetalTextureCacheFlush(_textureCache, 0);
    return CVMetalTextureGetTexture(_cvTexture);
}
@end

#pragma mark - 4. 真正的 LiquidGlassView 渲染器
@interface LiquidGlassView : UIView <MTKViewDelegate>
@property (nonatomic, strong) UIImage *sourceImage;
@property (nonatomic, assign) CGPoint sourceOrigin;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) CGFloat bezelWidth;
@property (nonatomic, assign) CGFloat glassThickness;
@property (nonatomic, assign) CGFloat refractionScale;
@property (nonatomic, assign) CGFloat refractiveIndex;
@property (nonatomic, assign) CGFloat specularOpacity;
@property (nonatomic, assign) CGFloat blur;
- (void)scheduleDraw;
@end

@implementation LiquidGlassView {
    MTKView *_mtkView;
    LGZeroCopyBridge *_bridge;
    id<MTLTexture> _bgTexture;
    id<MTLTexture> _blurredTexture;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        LGEnsureSharedGlassPipelinesReady();
        _mtkView = [[MTKView alloc] initWithFrame:self.bounds device:sDevice];
        _mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        _mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0);
        _mtkView.framebufferOnly = NO;
        _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _mtkView.paused = YES;
        _mtkView.enableSetNeedsDisplay = NO;
        _mtkView.opaque = NO;
        _mtkView.layer.opaque = NO;
        _mtkView.delegate = self;
        [self addSubview:_mtkView];
        self.clipsToBounds = YES;
    }
    return self;
}

- (void)setCornerRadius:(CGFloat)r {
    _cornerRadius = r;
    self.layer.cornerRadius = r;
}

- (void)setSourceImage:(UIImage *)image {
    _sourceImage = image; 
    if (!image) return;
    
    NSUInteger w = (NSUInteger)(image.size.width * image.scale);
    NSUInteger h = (NSUInteger)(image.size.height * image.scale);
    if (!_bridge) _bridge = [[LGZeroCopyBridge alloc] init];
    if ([_bridge bufferWidth] != w || [_bridge bufferHeight] != h) {
        [_bridge setupBufferWithWidth:w height:h];
        _blurredTexture = nil;
    }
    _bgTexture = [_bridge renderWithActions:^(CGContextRef ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, w, h));
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image.CGImage);
    }];
    
    if (!_blurredTexture && _bgTexture) {
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:_bgTexture.width height:_bgTexture.height mipmapped:NO];
        rd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        _blurredTexture = [sDevice newTextureWithDescriptor:rd];
    }
    if (_bgTexture && _blurredTexture) {
        id<MTLCommandBuffer> cmdBuf = [sCommandQueue commandBuffer];
        float sigma = MAX((self.blur * UIScreen.mainScreen.scale) * 0.5f, 0.1f);
        MPSImageGaussianBlur *blurKernel = [[MPSImageGaussianBlur alloc] initWithDevice:sDevice sigma:sigma];
        blurKernel.edgeMode = MPSImageEdgeModeClamp;
        [blurKernel encodeToCommandBuffer:cmdBuf sourceTexture:_bgTexture destinationTexture:_blurredTexture];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];
    }
    [self scheduleDraw];
}

- (void)scheduleDraw {
    [_mtkView draw];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size { }

- (void)drawInMTKView:(MTKView *)view {
    if (!sPipeline || !_blurredTexture || self.hidden || self.alpha <= 0.01) return;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    MTLRenderPassDescriptor *passDesc = view.currentRenderPassDescriptor;
    if (!drawable || !passDesc) return;
    id<MTLCommandBuffer> cmdBuf = [sCommandQueue commandBuffer];
    
    CGFloat scale = UIScreen.mainScreen.scale;
    CGRect screenRect = [self convertRect:self.bounds toView:nil];
    
    struct {
        vector_float2 resolution;
        vector_float2 screenResolution;
        vector_float2 cardOrigin;
        vector_float2 wallpaperResolution;
        float radius;
        float bezelWidth;
        float glassThickness;
        float refractionScale;
        float refractiveIndex;
        float specularOpacity;
        float specularAngle;
        float blur;
        vector_float2 wallpaperOrigin;
        float samplingOrientation;
        float hasShapeMask;
    } u = {
        .resolution = { (float)(screenRect.size.width * scale), (float)(screenRect.size.height * scale) },
        .screenResolution = { (float)(UIScreen.mainScreen.bounds.size.width * scale), (float)(UIScreen.mainScreen.bounds.size.height * scale) },
        .cardOrigin = { (float)(screenRect.origin.x * scale), (float)(screenRect.origin.y * scale) },
        .wallpaperResolution = { (float)_blurredTexture.width, (float)_blurredTexture.height },
        .radius = (float)(_cornerRadius * scale),
        .bezelWidth = (float)(_bezelWidth * scale),
        .glassThickness = (float)_glassThickness,
        .refractionScale = (float)_refractionScale,
        .refractiveIndex = (float)_refractiveIndex,
        .specularOpacity = (float)_specularOpacity,
        .specularAngle = 2.2689280f,
        .blur = (float)(_blur * scale),
        .wallpaperOrigin = { (float)(_sourceOrigin.x * scale), (float)(_sourceOrigin.y * scale) },
        .samplingOrientation = 1.0f,
        .hasShapeMask = 0.0f
    };
    
    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:passDesc];
    [enc setRenderPipelineState:sPipeline];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentTexture:_blurredTexture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
}
@end

#pragma mark - 5. LGSwitchInsetShadowView
@interface LGSwitchInsetShadowView : UIView
@end
@implementation LGSwitchInsetShadowView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.layer.compositingFilter = @"multiplyBlendMode";
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat shadowRadius = 3.5;
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, -1.0, -shadowRadius * 0.5)
                                                    cornerRadius:CGRectGetHeight(self.bounds) * 0.5];
    UIBezierPath *inner = [[UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 0.0, shadowRadius * 0.55)
                                                      cornerRadius:CGRectGetHeight(self.bounds) * 0.5] bezierPathByReversingPath];
    [path appendPath:inner];
    self.layer.shadowPath = path.CGPath;
    self.layer.shadowColor = [UIColor colorWithWhite:0.0 alpha:1.0].CGColor;
    self.layer.shadowOpacity = 0.18;
    self.layer.shadowRadius = shadowRadius;
    self.layer.shadowOffset = CGSizeMake(0.0, shadowRadius * 0.75);
}
@end

#pragma mark - 6. LGRenderSwitchBackdropImage
static UIImage *LGRenderSwitchBackdropImage(CGSize size, UIColor *backgroundColor, UIColor *trackColor, UIColor *fillColor, UIColor *sheenColor, UIColor *glassLiftColor, CGRect localTrackRect, CGFloat fillEndX) {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    [backgroundColor setFill];
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));
    CGFloat radius = CGRectGetHeight(localTrackRect) * 0.5;
    UIBezierPath *trackPath = [UIBezierPath bezierPathWithRoundedRect:localTrackRect cornerRadius:radius];
    [trackColor setFill];
    [trackPath fill];
    CGRect fillRect = CGRectMake(CGRectGetMinX(localTrackRect), CGRectGetMinY(localTrackRect), fillEndX - CGRectGetMinX(localTrackRect), CGRectGetHeight(localTrackRect));
    if (fillRect.size.width > 0.0) {
        UIBezierPath *fillPath = [UIBezierPath bezierPathWithRoundedRect:fillRect cornerRadius:radius];
        [fillColor setFill];
        [fillPath fill];
    }
    [sheenColor setFill];
    CGContextFillRect(context, CGRectMake(0, 0, size.width, fmin(12.0, size.height * 0.35)));
    if (CGColorGetAlpha(glassLiftColor.CGColor) > 0.001) {
        UIBezierPath *liftPath = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(localTrackRect, -30.0, -14.0) cornerRadius:CGRectGetHeight(localTrackRect) * 3.0];
        [glassLiftColor setFill];
        [liftPath fill];
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

#pragma mark - 7. LiquidGlassSwitch
@interface LiquidGlassSwitch ()
@property (nonatomic, strong) UIView *trackView;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UIView *contractedThumbView;
@property (nonatomic, strong) LiquidGlassView *glassThumbView;
@property (nonatomic, strong) LGSwitchInsetShadowView *glassInsetShadowView;
@property (nonatomic, strong) UIImpactFeedbackGenerator *feedbackGenerator;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL isTrackingTouch;
@property (nonatomic, assign) CGFloat renderedProgress;
@property (nonatomic, assign) CGFloat targetProgress;
@property (nonatomic, assign) CGSize renderedThumbSize;
@property (nonatomic, assign) CGSize targetThumbSize;
@property (nonatomic, assign) CGFloat renderedExpansion;
@property (nonatomic, assign) CGFloat targetExpansion;
@property (nonatomic, assign) CGFloat renderedFillAlpha;
@property (nonatomic, assign) CGFloat targetFillAlpha;
@property (nonatomic, assign) CFTimeInterval lastDisplayLinkTimestamp;
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) CGFloat dragStartLocation;
@property (nonatomic, assign) CGFloat dragStartThumbCenterX;
@property (nonatomic, assign) CFTimeInterval touchBeganTime;
@end

@implementation LiquidGlassSwitch

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        _renderedProgress = 0.0;
        _targetProgress = 0.0;
        _renderedThumbSize = CGSizeMake(36.0, 24.0);
        _targetThumbSize = CGSizeMake(36.0, 24.0);
        _renderedExpansion = 0.0;
        _targetExpansion = 0.0;
        _renderedFillAlpha = 0.0;
        _targetFillAlpha = 0.0;
        
        _trackView = [[UIView alloc] initWithFrame:CGRectZero];
        _trackView.userInteractionEnabled = NO;
        [self addSubview:_trackView];
        
        _fillView = [[UIView alloc] initWithFrame:CGRectZero];
        _fillView.userInteractionEnabled = NO;
        [_trackView addSubview:_fillView];
        
        _contractedThumbView = [[UIView alloc] initWithFrame:CGRectZero];
        _contractedThumbView.userInteractionEnabled = NO;
        [self addSubview:_contractedThumbView];
        
        _glassThumbView = [[LiquidGlassView alloc] initWithFrame:CGRectZero];
        _glassThumbView.userInteractionEnabled = NO;
        _glassThumbView.bezelWidth = 6.0;
        _glassThumbView.glassThickness = 20.0;
        _glassThumbView.refractionScale = 1.5;
        _glassThumbView.refractiveIndex = 1.5;
        _glassThumbView.specularOpacity = 0.04;
        _glassThumbView.blur = 18.0;
        _glassThumbView.alpha = 0.0;
        _glassThumbView.hidden = YES;
        [self addSubview:_glassThumbView];
        
        _glassInsetShadowView = [[LGSwitchInsetShadowView alloc] initWithFrame:_glassThumbView.bounds];
        _glassInsetShadowView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_glassThumbView addSubview:_glassInsetShadowView];
        
        _feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    }
    return self;
}

- (void)updateMaterialColors {
    BOOL darkMode = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    self.trackView.backgroundColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.18] : [UIColor colorWithWhite:0.20 alpha:0.10];
    self.fillView.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:darkMode ? 0.78 : 0.92];
    
    self.contractedThumbView.backgroundColor = UIColor.whiteColor;
    self.contractedThumbView.layer.shadowColor = UIColor.blackColor.CGColor;
    self.contractedThumbView.layer.shadowOpacity = 0.12;
    self.contractedThumbView.layer.shadowRadius = 5.0;
    
    self.glassThumbView.specularOpacity = darkMode ? 0.02 : 0.0;
    self.glassInsetShadowView.alpha = darkMode ? 0.68 : 1.0;
}

- (CGRect)trackFrame {
    CGSize size = CGSizeMake(63.0, 28.0);
    return CGRectMake(floor((CGRectGetWidth(self.bounds) - size.width) * 0.5),
                      floor((CGRectGetHeight(self.bounds) - size.height) * 0.5), size.width, size.height);
}

- (CGFloat)minCenterX { return CGRectGetMinX([self trackFrame]) + 20.0; }
- (CGFloat)maxCenterX { return CGRectGetMaxX([self trackFrame]) - 20.0; }
- (CGFloat)resolvedCenterX { return [self minCenterX] + (([self maxCenterX] - [self minCenterX]) * _renderedProgress); }

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -10.0, -10.0), point);
}

- (void)startDisplayLink {
    if (!self.displayLink) {
        self.lastDisplayLinkTimestamp = 0.0;
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)stopDisplayLink {
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval dt = self.lastDisplayLinkTimestamp > 0.0 ? (link.timestamp - self.lastDisplayLinkTimestamp) : (1.0 / 60.0);
    self.lastDisplayLinkTimestamp = link.timestamp;
    CGFloat frameFactor = fmin(MAX(dt * 60.0, 0.35), 1.4);
    CGFloat progressLerp = (self.isTrackingTouch ? 0.34 : 0.22) * frameFactor;
    CGFloat sizeLerp = (self.isTrackingTouch ? 0.36 : 0.24) * frameFactor;
    BOOL expanding = self.targetExpansion > self.renderedExpansion;
    CGFloat expansionLerp = ((self.isTrackingTouch || expanding) ? 0.42 : 0.14) * frameFactor;
    
    self.renderedProgress += (self.targetProgress - self.renderedProgress) * progressLerp;
    self.renderedExpansion += (self.targetExpansion - self.renderedExpansion) * expansionLerp;
    self.renderedFillAlpha += (self.targetFillAlpha - self.renderedFillAlpha) * (0.1 * frameFactor);
    
    CGSize rSize = self.renderedThumbSize;
    rSize.width += (self.targetThumbSize.width - rSize.width) * sizeLerp;
    rSize.height += (self.targetThumbSize.height - rSize.height) * sizeLerp;
    self.renderedThumbSize = rSize;
    
    [self refreshGlassBackdrop];
    [self updateVisuals];
    
    if (!self.isTrackingTouch && fabs(self.targetProgress - self.renderedProgress) < 0.002 &&
        fabs(self.targetThumbSize.width - self.renderedThumbSize.width) < 0.05 && fabs(self.targetExpansion - self.renderedExpansion) < 0.01) {
        self.renderedProgress = self.targetProgress;
        self.renderedThumbSize = self.targetThumbSize;
        self.renderedExpansion = self.targetExpansion;
        [self stopDisplayLink];
    }
}

- (void)refreshGlassBackdrop {
    if (!self.window || self.renderedExpansion < 0.01) return;
    CGRect trackFrame = [self trackFrame];
    CGRect captureRect = CGRectInset(trackFrame, -20.0, -20.0);
    
    BOOL darkMode = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    UIColor *backgroundColor = self.superview.backgroundColor ?: (self.window.backgroundColor ?: [UIColor systemBackgroundColor]);
    UIColor *trackColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.18] : [UIColor colorWithWhite:0.20 alpha:0.10];
    UIColor *sheenColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.045] : [UIColor colorWithWhite:1.0 alpha:0.12];
    UIColor *liftColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.14] : [UIColor colorWithWhite:1.0 alpha:0.0];
    UIColor *fillColor = [self.fillView.backgroundColor colorWithAlphaComponent:self.renderedFillAlpha];
    
    CGRect localTrackRect = CGRectOffset(trackFrame, -CGRectGetMinX(captureRect), -CGRectGetMinY(captureRect));
    CGFloat fillEndX = CGRectGetMaxX(localTrackRect);
    
    UIImage *image = LGRenderSwitchBackdropImage(captureRect.size, backgroundColor, trackColor, fillColor, sheenColor, liftColor, localTrackRect, fillEndX);
    self.glassThumbView.sourceOrigin = [self convertPoint:captureRect.origin toView:nil];
    self.glassThumbView.sourceImage = image; 
}

- (void)updateVisuals {
    CGRect trackFrame = [self trackFrame];
    self.trackView.frame = trackFrame;
    self.trackView.layer.cornerRadius = trackFrame.size.height * 0.5;
    
    self.fillView.frame = CGRectMake(0, 0, trackFrame.size.width, trackFrame.size.height);
    self.fillView.layer.cornerRadius = trackFrame.size.height * 0.5;
    self.fillView.alpha = self.renderedFillAlpha;
    
    CGFloat centerX = [self resolvedCenterX];
    CGFloat midY = CGRectGetMidY(trackFrame);
    CGFloat expansion = fmax(0.0, fmin(self.renderedExpansion, 1.0));
    CGFloat visualExpansion = expansion * expansion * (3.0 - (2.0 * expansion));
    
    CGFloat contractedScale = 1.0 + (0.06 * visualExpansion);
    CGFloat glassScale = 0.92 + (0.08 * visualExpansion);
    
    self.contractedThumbView.frame = CGRectMake(centerX - 18.0, midY - 12.0, 36.0, 24.0);
    self.glassThumbView.frame = CGRectMake(centerX - self.renderedThumbSize.width * 0.5,
                                           midY - self.renderedThumbSize.height * 0.5,
                                           self.renderedThumbSize.width,
                                           self.renderedThumbSize.height);
                                           
    self.contractedThumbView.layer.cornerRadius = 12.0;
    self.glassThumbView.cornerRadius = self.renderedThumbSize.height * 0.5;
    
    self.glassThumbView.alpha = visualExpansion;
    self.contractedThumbView.alpha = 1.0 - visualExpansion;
    self.glassThumbView.transform = CGAffineTransformMakeScale(glassScale, glassScale);
    self.contractedThumbView.transform = CGAffineTransformMakeScale(contractedScale, contractedScale);
    self.glassThumbView.hidden = visualExpansion < 0.01;
    self.contractedThumbView.hidden = visualExpansion > 0.99;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateMaterialColors];
    [self updateVisuals];
}

// ============== 触摸追踪修复区 ==============

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    self.isTrackingTouch = YES;
    self.isDragging = NO;
    self.touchBeganTime = CACurrentMediaTime();
    
    // 【修复】：用 touch 替代了错误的 touches.anyObject
    self.dragStartLocation = [touch locationInView:self].x;
    
    self.dragStartThumbCenterX = [self resolvedCenterX];
    self.targetExpansion = 1.0;
    self.targetThumbSize = CGSizeMake(54.0, 34.0);
    [self startDisplayLink];
    [self.feedbackGenerator prepare];
    [self refreshGlassBackdrop];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    if (!self.isDragging && (CACurrentMediaTime() - self.touchBeganTime) >= 0.15) {
        self.isDragging = YES;
    }
    
    // 【修复】：用 touch 替代了错误的 touches.anyObject
    CGFloat currentX = [touch locationInView:self].x;
    
    CGFloat translation = currentX - self.dragStartLocation;
    CGFloat newCenterX = self.dragStartThumbCenterX + translation;
    
    CGFloat minX = [self minCenterX];
    CGFloat maxX = [self maxCenterX];
    CGFloat clampedCenterX = newCenterX;
    if (clampedCenterX < minX) clampedCenterX = minX - sqrt(minX - clampedCenterX);
    if (clampedCenterX > maxX) clampedCenterX = maxX + sqrt(clampedCenterX - maxX);
    
    self.targetProgress = fmax(0.0, fmin((clampedCenterX - minX) / (maxX - minX), 1.0));
    [self startDisplayLink];
    [self refreshGlassBackdrop];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    self.isTrackingTouch = NO;
    self.targetExpansion = 0.0;
    self.targetThumbSize = CGSizeMake(36.0, 24.0);
    
    BOOL tappedToggle = (CACurrentMediaTime() - self.touchBeganTime) < 0.15 && !self.isDragging;
    BOOL newOn = tappedToggle ? !self.on : (self.targetProgress >= 0.5);
    
    if (self.on != newOn) {
        [self.feedbackGenerator impactOccurred];
        self.on = newOn;
        if (self.changeAction) self.changeAction(newOn);
    }
    
    self.targetProgress = newOn ? 1.0 : 0.0;
    self.targetFillAlpha = newOn ? 1.0 : 0.0;
    [self startDisplayLink];
    [self refreshGlassBackdrop];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    [self endTrackingWithTouch:nil withEvent:event];
}

- (void)setOnWithoutAction:(BOOL)on {
    _on = on;
    self.targetProgress = on ? 1.0 : 0.0;
    self.targetFillAlpha = on ? 1.0 : 0.0;
    self.targetExpansion = 0.0;
    self.targetThumbSize = CGSizeMake(36.0, 24.0);
    [self startDisplayLink];
}

@end
