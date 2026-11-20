#import "RF.h"
#import <GLKit/GLKit.h>
#import <OpenGLES/ES2/gl.h>

#pragma mark - Vídeo (GLKView + textura RGB565)

static const char *kRFVertexShader =
    "attribute vec2 aPos;\n"
    "attribute vec2 aTex;\n"
    "varying vec2 vTex;\n"
    "void main() { vTex = aTex; gl_Position = vec4(aPos, 0.0, 1.0); }\n";

static const char *kRFFragmentShader =
    "precision mediump float;\n"
    "varying vec2 vTex;\n"
    "uniform sampler2D uTex;\n"
    "void main() { gl_FragColor = texture2D(uTex, vTex); }\n";

#define RF_TEX_SIZE 1024   // o PS1 vai de 256x224 até 640x480 (modo entrelaçado)

@interface RFGLView () <GLKViewDelegate>
@property (nonatomic, strong) EAGLContext *context;
@property (nonatomic, strong) GLKView *glView;
@property (nonatomic, assign) GLuint program;
@property (nonatomic, assign) GLuint texture;
@property (nonatomic, assign) GLint posAttr;
@property (nonatomic, assign) GLint texAttr;
@property (nonatomic, assign) uint16_t *staging;
@property (nonatomic, assign) unsigned lastWidth;
@property (nonatomic, assign) unsigned lastHeight;
@end

@implementation RFGLView

static GLuint rf_compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    return s;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        _glView = [[GLKView alloc] initWithFrame:self.bounds context:_context];
        _glView.delegate = self;
        _glView.enableSetNeedsDisplay = NO;
        _glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _glView.userInteractionEnabled = NO;
        // Desenha em 1x (1024x768) em vez de Retina (2048x1536): 4x menos pixels para a GPU do A5X.
        // A imagem do PS1 costuma ter 320x240, então não se perde nitidez visível.
        _glView.contentScaleFactor = 1.0;
        _glView.opaque = YES;
        [self addSubview:_glView];
        _staging = calloc(RF_TEX_SIZE * RF_TEX_SIZE, sizeof(uint16_t));
        [self setupGL];
    }
    return self;
}

- (void)dealloc {
    [EAGLContext setCurrentContext:self.context];
    if (_texture) glDeleteTextures(1, &_texture);
    if (_program) glDeleteProgram(_program);
    [EAGLContext setCurrentContext:nil];
    free(_staging);
}

- (void)setupGL {
    [EAGLContext setCurrentContext:self.context];
    GLuint vs = rf_compile(GL_VERTEX_SHADER, kRFVertexShader);
    GLuint fs = rf_compile(GL_FRAGMENT_SHADER, kRFFragmentShader);
    _program = glCreateProgram();
    glAttachShader(_program, vs);
    glAttachShader(_program, fs);
    glLinkProgram(_program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    _posAttr = glGetAttribLocation(_program, "aPos");
    _texAttr = glGetAttribLocation(_program, "aTex");

    glGenTextures(1, &_texture);
    glBindTexture(GL_TEXTURE_2D, _texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, RF_TEX_SIZE, RF_TEX_SIZE, 0, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, _staging);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    [self applyFilter];
}

- (void)applyFilter {
    [EAGLContext setCurrentContext:self.context];
    glBindTexture(GL_TEXTURE_2D, _texture);
    GLint f = self.smooth ? GL_LINEAR : GL_NEAREST;
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, f);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, f);
}

- (void)setSmooth:(BOOL)smooth {
    _smooth = smooth;
    [self applyFilter];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    self.glView.contentScaleFactor = 1.0;
}

- (void)drawFrame {
    [self.glView display];
}

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect {
    unsigned w = 0, h = 0;
    size_t pitch = 0;
    const void *data = [[RFCore shared] frameData:&w height:&h pitch:&pitch];

    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    if (!data || !w || !h) {
        if (!self.lastWidth) return;
        w = self.lastWidth;
        h = self.lastHeight;
    } else {
        w = MIN(w, RF_TEX_SIZE);
        h = MIN(h, RF_TEX_SIZE);
        glBindTexture(GL_TEXTURE_2D, _texture);
        if (pitch == w * 2) {
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, data);
        } else {
            // O core usa um pitch maior que a largura: copia linha a linha
            const uint8_t *src = data;
            for (unsigned y = 0; y < h; y++) {
                memcpy(self.staging + y * w, src + y * pitch, w * 2);
            }
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, self.staging);
        }
        self.lastWidth = w;
        self.lastHeight = h;
    }

    float u = (float)w / RF_TEX_SIZE;
    float v = (float)h / RF_TEX_SIZE;
    const GLfloat quad[] = {
        -1, -1, 0, v,
         1, -1, u, v,
        -1,  1, 0, 0,
         1,  1, u, 0,
    };
    glUseProgram(_program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _texture);
    glUniform1i(glGetUniformLocation(_program, "uTex"), 0);
    glVertexAttribPointer(_posAttr, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), quad);
    glVertexAttribPointer(_texAttr, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), quad + 2);
    glEnableVertexAttribArray(_posAttr);
    glEnableVertexAttribArray(_texAttr);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

@end

#pragma mark - Controle na tela

typedef struct {
    CGPoint center;
    CGFloat radius;
    uint32_t mask;
    __unsafe_unretained NSString *label;
    BOOL pill;       // botão alongado (L1, L2, R1, R2, Select, Start)
    int symbol;      // botões de face: 1 triângulo, 2 círculo, 3 xis, 4 quadrado; 0 = texto
} RFButton;

// 0 círculo, 1 xis, 2 triângulo, 3 quadrado, 4 L1, 5 R1, 6 L2, 7 R2, 8 SELECT, 9 START
#define RF_BUTTONS 10

@interface RFTouchPad ()
@property (nonatomic, assign) CGPoint dpadCenter;
@property (nonatomic, assign) CGFloat dpadRadius;
@property (nonatomic, assign) CGRect menuRect;
@property (nonatomic, assign) uint32_t drawnMask;
- (void)drawControlsInContext:(CGContextRef)ctx;
@end

// Pedaço pequeno do controle na tela. A view grande (RFTouchPad) não desenha nada e não tem
// bitmap próprio: assim o iOS só mistura em cima do vídeo as áreas dos botões, e não a tela inteira.
@interface RFPadPart : UIView
@property (nonatomic, weak) RFTouchPad *owner;
@end

@implementation RFPadPart
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(ctx, -self.frame.origin.x, -self.frame.origin.y);
    [self.owner drawControlsInContext:ctx];
}
@end

@implementation RFTouchPad {
    RFButton _buttons[RF_BUTTONS];
    RFPadPart *_dpadPart, *_abcPart, *_startPart, *_menuPart, *_lPart, *_rPart;   // L/R levam L1+L2 e R1+R2
}

- (RFPadPart *)makePart {
    RFPadPart *part = [[RFPadPart alloc] initWithFrame:CGRectZero];
    part.owner = self;
    part.backgroundColor = [UIColor clearColor];
    part.opaque = NO;
    part.userInteractionEnabled = NO;
    part.contentMode = UIViewContentModeRedraw;
    [self addSubview:part];
    return part;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = nil;
        self.opaque = NO;
        self.multipleTouchEnabled = YES;
        _dpadPart = [self makePart];
        _abcPart = [self makePart];
        _startPart = [self makePart];
        _lPart = [self makePart];
        _rPart = [self makePart];
        _menuPart = [self makePart];
    }
    return self;
}

- (void)setNeedsDisplay {
    // Não chama o super: esta view não tem desenho próprio
    [_dpadPart setNeedsDisplay];
    [_abcPart setNeedsDisplay];
    [_startPart setNeedsDisplay];
    [_lPart setNeedsDisplay];
    [_rPart setNeedsDisplay];
    [_menuPart setNeedsDisplay];
}

- (void)setControlsHidden:(BOOL)controlsHidden {
    _controlsHidden = controlsHidden;
    rf_touch_mask = 0;
    _dpadPart.hidden = _abcPart.hidden = _startPart.hidden = _lPart.hidden = _rPart.hidden = controlsHidden;
    [self setNeedsDisplay];
}

static CGRect rf_button_rect(RFButton b) {
    CGRect br = CGRectMake(b.center.x - b.radius, b.center.y - b.radius, 2 * b.radius, 2 * b.radius);
    return b.pill ? CGRectInset(br, -b.radius * 0.8, b.radius * 0.35) : br;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    BOOL landscape = s.width > s.height;
    CGFloat unit = MIN(s.width, s.height);
    CGFloat btn = unit * (landscape ? 0.075 : 0.085);

    CGFloat bottomY;
    if (landscape) {
        bottomY = s.height - unit * 0.22;
    } else {
        // Retrato: controles na área abaixo do vídeo
        CGFloat top = CGRectGetMaxY(self.gameRect);
        bottomY = top + (s.height - top) * 0.5;
    }
    self.dpadRadius = unit * (landscape ? 0.15 : 0.17);
    self.dpadCenter = CGPointMake(self.dpadRadius + unit * 0.05, bottomY);

    // Quatro botões de face em losango: triângulo em cima, círculo à direita, xis embaixo, quadrado à esquerda
    CGFloat d = btn * 1.25;
    CGFloat cx = s.width - unit * 0.06 - btn - d;
    CGFloat cy = bottomY;
    _buttons[0] = (RFButton){CGPointMake(cx + d, cy), btn, RF_PS_CIRCLE, @"", NO, 2};
    _buttons[1] = (RFButton){CGPointMake(cx, cy + d), btn, RF_PS_CROSS, @"", NO, 3};
    _buttons[2] = (RFButton){CGPointMake(cx, cy - d), btn, RF_PS_TRIANGLE, @"", NO, 1};
    _buttons[3] = (RFButton){CGPointMake(cx - d, cy), btn, RF_PS_SQUARE, @"", NO, 4};

    // L1/L2 e R1/R2 nos cantos de cima. Na horizontal L2/R2 ficam por cima de L1/R1;
    // na vertical (pouco espaço acima do direcional) ficam lado a lado, numa fileira só.
    CGFloat lx = unit * 0.05 + btn * 1.4, rx = s.width - unit * 0.05 - btn * 1.4;
    CGFloat shoulderY, triggerY, l2x = lx, r2x = rx;
    if (landscape) {
        shoulderY = 150;
        triggerY = shoulderY - btn * 1.25;
    } else {
        shoulderY = triggerY = CGRectGetMaxY(self.gameRect) + btn * 0.9;
        l2x = lx + btn * 2.7;
        r2x = rx - btn * 2.7;
    }
    _buttons[4] = (RFButton){CGPointMake(lx, shoulderY), btn * 0.7, RF_PS_L1, @"L1", YES, 0};
    _buttons[5] = (RFButton){CGPointMake(rx, shoulderY), btn * 0.7, RF_PS_R1, @"R1", YES, 0};
    _buttons[6] = (RFButton){CGPointMake(l2x, triggerY), btn * 0.7, RF_PS_L2, @"L2", YES, 0};
    _buttons[7] = (RFButton){CGPointMake(r2x, triggerY), btn * 0.7, RF_PS_R2, @"R2", YES, 0};
    CGFloat smallY = s.height - btn * 0.9;
    _buttons[8] = (RFButton){CGPointMake(s.width / 2.0 - btn * 1.35, smallY), btn * 0.55, RF_PS_SELECT, @"SELECT", YES, 0};
    _buttons[9] = (RFButton){CGPointMake(s.width / 2.0 + btn * 1.35, smallY), btn * 0.55, RF_PS_START, @"START", YES, 0};

    CGFloat m = 44;
    self.menuRect = CGRectMake(s.width - m - 10, 10, m, m);

    CGFloat r = self.dpadRadius;
    _dpadPart.frame = CGRectIntegral(CGRectInset(CGRectMake(self.dpadCenter.x - r, self.dpadCenter.y - r, 2 * r, 2 * r), -4, -4));
    CGRect face = rf_button_rect(_buttons[0]);
    for (int i = 1; i < 4; i++) face = CGRectUnion(face, rf_button_rect(_buttons[i]));
    _abcPart.frame = CGRectIntegral(CGRectInset(face, -4, -4));
    _lPart.frame = CGRectIntegral(CGRectInset(CGRectUnion(rf_button_rect(_buttons[4]), rf_button_rect(_buttons[6])), -4, -4));
    _rPart.frame = CGRectIntegral(CGRectInset(CGRectUnion(rf_button_rect(_buttons[5]), rf_button_rect(_buttons[7])), -4, -4));
    _startPart.frame = CGRectIntegral(CGRectInset(CGRectUnion(rf_button_rect(_buttons[8]), rf_button_rect(_buttons[9])), -4, -4));
    _menuPart.frame = CGRectIntegral(CGRectInset(self.menuRect, -3, -3));
    [self setNeedsDisplay];
}

- (uint32_t)maskForTouches:(NSSet *)touches {
    uint32_t mask = 0;
    for (UITouch *t in touches) {
        if (t.phase == UITouchPhaseEnded || t.phase == UITouchPhaseCancelled) continue;
        CGPoint p = [t locationInView:self];
        // Direcional (8 direções)
        CGFloat dx = p.x - self.dpadCenter.x, dy = p.y - self.dpadCenter.y;
        CGFloat dist = sqrt(dx * dx + dy * dy);
        if (dist < self.dpadRadius * 1.6) {
            if (dist > self.dpadRadius * 0.18) {
                double angle = atan2(-dy, dx) * 180.0 / M_PI;   // 0 = direita, 90 = cima
                if (angle < 0) angle += 360;
                if (angle >= 22.5 && angle < 157.5) mask |= RF_UP;
                if (angle >= 202.5 && angle < 337.5) mask |= RF_DOWN;
                if (angle >= 112.5 && angle < 247.5) mask |= RF_LEFT;
                if (angle < 67.5 || angle >= 292.5) mask |= RF_RIGHT;
            }
            continue;
        }
        // Botão mais próximo dentro do alcance
        int best = -1;
        CGFloat bestDist = CGFLOAT_MAX;
        for (int i = 0; i < RF_BUTTONS; i++) {
            CGFloat bx = p.x - _buttons[i].center.x, by = p.y - _buttons[i].center.y;
            CGFloat d = sqrt(bx * bx + by * by);
            BOOL inside = _buttons[i].pill
                ? CGRectContainsPoint(CGRectInset(rf_button_rect(_buttons[i]), -_buttons[i].radius * 0.4, -_buttons[i].radius * 0.4), p)
                : d < _buttons[i].radius * 1.45;
            if (inside && d < bestDist) {
                best = i;
                bestDist = d;
            }
        }
        if (best >= 0) mask |= _buttons[best].mask;
    }
    return mask;
}

- (void)updateWithEvent:(UIEvent *)event {
    if (self.controlsHidden) return;
    uint32_t mask = [self maskForTouches:[event touchesForView:self]];
    if (mask != rf_touch_mask) {
        rf_touch_mask = mask;
        RFInputChanged();
    }
    if (mask != self.drawnMask) {
        self.drawnMask = mask;
        [self setNeedsDisplay];
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        if (CGRectContainsPoint(CGRectInset(self.menuRect, -12, -12), [t locationInView:self])) {
            if (self.menuHandler) self.menuHandler();
            return;
        }
    }
    [self updateWithEvent:event];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [self updateWithEvent:event];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [self updateWithEvent:event];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    rf_touch_mask = 0;
    self.drawnMask = 0;
    [self setNeedsDisplay];
}

- (void)drawControlsInContext:(CGContextRef)ctx {
    UIColor *line = [UIColor colorWithWhite:1 alpha:0.35];
    UIColor *fill = [UIColor colorWithWhite:1 alpha:0.10];
    UIColor *pressed = [UIColor colorWithWhite:1 alpha:0.40];

    // Botão de menu (sempre visível)
    UIBezierPath *menu = [UIBezierPath bezierPathWithRoundedRect:self.menuRect cornerRadius:10];
    [[UIColor colorWithWhite:0 alpha:0.35] setFill];
    [menu fill];
    [line setStroke];
    [menu stroke];
    for (int i = 0; i < 3; i++) {
        CGFloat y = CGRectGetMinY(self.menuRect) + 14 + i * 8;
        CGContextFillRect(ctx, CGRectMake(CGRectGetMinX(self.menuRect) + 11, y, 22, 2.5));
    }
    if (self.controlsHidden) return;

    uint32_t mask = self.drawnMask;
    CGPoint c = self.dpadCenter;
    CGFloat r = self.dpadRadius;
    UIBezierPath *base = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r)];
    [fill setFill];
    [base fill];
    [line setStroke];
    base.lineWidth = 2;
    [base stroke];

    // Cruz do direcional
    CGFloat arm = r * 0.36;
    struct { CGRect rect; uint32_t bit; } arms[4] = {
        {CGRectMake(c.x - arm / 2, c.y - r * 0.85, arm, r * 0.62), RF_UP},
        {CGRectMake(c.x - arm / 2, c.y + r * 0.23, arm, r * 0.62), RF_DOWN},
        {CGRectMake(c.x - r * 0.85, c.y - arm / 2, r * 0.62, arm), RF_LEFT},
        {CGRectMake(c.x + r * 0.23, c.y - arm / 2, r * 0.62, arm), RF_RIGHT},
    };
    for (int i = 0; i < 4; i++) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:arms[i].rect cornerRadius:4];
        [(mask & arms[i].bit ? pressed : fill) setFill];
        [p fill];
        [line setStroke];
        [p stroke];
    }

    // Botões em cinza translúcido, com os símbolos geométricos desenhados em traço claro
    UIColor *faceFill = [UIColor colorWithWhite:0.08 alpha:0.45];
    UIColor *facePressed = [UIColor colorWithWhite:1 alpha:0.45];
    UIColor *mark = [UIColor colorWithWhite:1 alpha:0.75];
    for (int i = 0; i < RF_BUTTONS; i++) {
        RFButton b = _buttons[i];
        BOOL down = (mask & b.mask) != 0;
        UIBezierPath *p = b.pill ? [UIBezierPath bezierPathWithRoundedRect:rf_button_rect(b) cornerRadius:b.radius * 0.6]
                                 : [UIBezierPath bezierPathWithOvalInRect:rf_button_rect(b)];
        [(b.symbol ? (down ? facePressed : faceFill) : (down ? pressed : fill)) setFill];
        [p fill];
        [line setStroke];
        p.lineWidth = 2;
        [p stroke];
        if (b.symbol) {
            CGFloat k = b.radius * 0.42;
            CGPoint c2 = b.center;
            UIBezierPath *sym = nil;
            switch (b.symbol) {
                case 1: {   // triângulo
                    sym = [UIBezierPath bezierPath];
                    [sym moveToPoint:CGPointMake(c2.x, c2.y - k)];
                    [sym addLineToPoint:CGPointMake(c2.x + k * 0.95, c2.y + k * 0.62)];
                    [sym addLineToPoint:CGPointMake(c2.x - k * 0.95, c2.y + k * 0.62)];
                    [sym closePath];
                    break;
                }
                case 2:     // círculo
                    sym = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c2.x - k * 0.85, c2.y - k * 0.85, k * 1.7, k * 1.7)];
                    break;
                case 3:     // xis
                    sym = [UIBezierPath bezierPath];
                    [sym moveToPoint:CGPointMake(c2.x - k * 0.75, c2.y - k * 0.75)];
                    [sym addLineToPoint:CGPointMake(c2.x + k * 0.75, c2.y + k * 0.75)];
                    [sym moveToPoint:CGPointMake(c2.x + k * 0.75, c2.y - k * 0.75)];
                    [sym addLineToPoint:CGPointMake(c2.x - k * 0.75, c2.y + k * 0.75)];
                    break;
                default:    // quadrado
                    sym = [UIBezierPath bezierPathWithRect:CGRectMake(c2.x - k * 0.72, c2.y - k * 0.72, k * 1.44, k * 1.44)];
                    break;
            }
            sym.lineWidth = MAX(2.5, b.radius * 0.11);
            sym.lineJoinStyle = kCGLineJoinRound;
            sym.lineCapStyle = kCGLineCapRound;
            [mark setStroke];
            [sym stroke];
            continue;
        }
        NSDictionary *attrs = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:b.radius * (b.label.length > 2 ? 0.55 : 0.75)],
                                 NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.7] };
        CGSize ts = [b.label sizeWithAttributes:attrs];
        [b.label drawAtPoint:CGPointMake(b.center.x - ts.width / 2, b.center.y - ts.height / 2) withAttributes:attrs];
    }
}

@end
