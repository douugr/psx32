// Visual inspirado na era do CD nos anos 90: caixas de CD (jewel case) com lombada escura,
// discos pretos com o brilho de arco-íris da face gravada, cinza claro de console, letreiros
// prateados e tipografia condensada dos anúncios da época. Nada de logos: só a linguagem visual.

#import "RF.h"
#import <QuartzCore/QuartzCore.h>

// Cor de destaque (azul elétrico). O nome segue o do MD16 para manter o resto do código igual.
UIColor *RFThemeRed(void) {
    return [UIColor colorWithRed:0.24 green:0.56 blue:1.00 alpha:1];
}

// Secundária: cinza claro de console
UIColor *RFThemeLilac(void) {
    return [UIColor colorWithRed:0.76 green:0.76 blue:0.79 alpha:1];
}

UIColor *RFThemeText(void) {
    return [UIColor colorWithWhite:0.94 alpha:1];
}

UIColor *RFThemeDim(void) {
    return [UIColor colorWithWhite:0.58 alpha:1];
}

UIColor *RFThemeCard(void) {
    return [UIColor colorWithRed:0.14 green:0.14 blue:0.16 alpha:1];
}

UIFont *RFThemeDisplayFont(CGFloat size) {
    return [UIFont fontWithName:@"Futura-CondensedExtraBold" size:size] ?: [UIFont boldSystemFontOfSize:size];
}

UIFont *RFThemeLabelFont(CGFloat size) {
    return [UIFont fontWithName:@"Futura-Medium" size:size] ?: [UIFont boldSystemFontOfSize:size];
}

// Grafite com linhas finas de tubo de TV (CRT)
UIColor *RFThemeGridColor(void) {
    static UIColor *color;
    if (color) return color;
    CGFloat h = 4;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(4, h), YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor colorWithRed:0.095 green:0.095 blue:0.11 alpha:1] setFill];
    CGContextFillRect(ctx, CGRectMake(0, 0, 4, h));
    CGFloat px = 1.0 / [UIScreen mainScreen].scale;
    [[UIColor colorWithRed:0.075 green:0.075 blue:0.085 alpha:1] setFill];
    CGContextFillRect(ctx, CGRectMake(0, h - px * 2, 4, px * 2));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    color = [UIColor colorWithPatternImage:img];
    return color;
}

UIView *RFThemeGridView(void) {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = RFThemeGridColor();
    return v;
}

// Cores do brilho de arco-íris de um CD (luz refletida nas trilhas)
static void rf_rainbow_colors(CGFloat comps[24]) {
    const CGFloat c[] = {
        0.35, 0.85, 1.00, 1,   // ciano
        0.45, 0.45, 1.00, 1,   // azul-violeta
        0.85, 0.40, 0.95, 1,   // magenta
        1.00, 0.50, 0.45, 1,   // coral
        1.00, 0.85, 0.35, 1,   // dourado
        0.55, 0.95, 0.60, 1,   // verde-claro
    };
    memcpy(comps, c, sizeof(c));
}

// Três faixas horizontais com o degradê de arco-íris, mais finas para baixo
void RFThemeDrawStripes(CGContextRef ctx, CGRect r, CGFloat width) {
    CGFloat comps[24];
    rf_rainbow_colors(comps);
    CGFloat locs[] = {0, 0.2, 0.4, 0.6, 0.8, 1};
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColorComponents(rgb, comps, locs, 6);
    CGColorSpaceRelease(rgb);
    CGFloat y = r.origin.y;
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat h = width * (1.0 - i * 0.3);
        CGContextSaveGState(ctx);
        CGContextSetAlpha(ctx, 1.0 - i * 0.25);
        CGContextClipToRect(ctx, CGRectMake(r.origin.x, y, r.size.width, h));
        CGContextDrawLinearGradient(ctx, g, CGPointMake(r.origin.x, 0), CGPointMake(CGRectGetMaxX(r), 0), 0);
        CGContextRestoreGState(ctx);
        y += h + width * 0.35;
    }
    CGGradientRelease(g);
}

// Disco preto visto pela face gravada: anéis, brilho de arco-íris em leque e o furo central
void RFThemeDrawDisc(CGContextRef ctx, CGRect r) {
    CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    CGFloat R = MIN(r.size.width, r.size.height) / 2.0;
    UIBezierPath *disc = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - R, c.y - R, 2 * R, 2 * R)];
    CGContextSaveGState(ctx);
    [disc addClip];
    [[UIColor colorWithRed:0.05 green:0.05 blue:0.07 alpha:1] setFill];
    UIRectFill(r);
    // Leques de arco-íris (dois, opostos, como a luz batendo no disco)
    CGFloat comps[24];
    rf_rainbow_colors(comps);
    for (int side = 0; side < 2; side++) {
        CGFloat a0 = side ? M_PI * 1.10 : M_PI * 0.10;
        for (int i = 0; i < 6; i++) {
            UIBezierPath *wedge = [UIBezierPath bezierPath];
            [wedge moveToPoint:c];
            [wedge addArcWithCenter:c radius:R startAngle:a0 + i * 0.09 endAngle:a0 + (i + 1) * 0.09 clockwise:YES];
            [wedge closePath];
            [[UIColor colorWithRed:comps[i * 4] green:comps[i * 4 + 1] blue:comps[i * 4 + 2] alpha:0.30] setFill];
            [wedge fill];
        }
    }
    // Anéis finos (trilhas)
    for (CGFloat k = 0.42; k < 0.98; k += 0.07) {
        UIBezierPath *ring = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - R * k, c.y - R * k, 2 * R * k, 2 * R * k)];
        ring.lineWidth = 0.6;
        [[UIColor colorWithWhite:1 alpha:0.06] setStroke];
        [ring stroke];
    }
    CGContextRestoreGState(ctx);
    // Área transparente perto do centro e o furo
    UIBezierPath *hub = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - R * 0.34, c.y - R * 0.34, R * 0.68, R * 0.68)];
    [[UIColor colorWithWhite:0.55 alpha:0.35] setFill];
    [hub fill];
    UIBezierPath *hole = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - R * 0.12, c.y - R * 0.12, R * 0.24, R * 0.24)];
    [[UIColor colorWithRed:0.095 green:0.095 blue:0.11 alpha:1] setFill];
    [hole fill];
    disc.lineWidth = 1;
    [[UIColor colorWithWhite:0.45 alpha:0.8] setStroke];
    [disc stroke];
}

// Letreiro prateado: metal escovado em degradê, contorno escuro e reflexo (logos de 1995-1998)
UIImage *RFThemeChromeText(NSString *text, CGFloat size) {
    UIFont *font = RFThemeDisplayFont(size);
    NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor]};
    CGSize ts = [text sizeWithAttributes:attrs];
    CGFloat pad = size * 0.12;
    CGSize canvas = CGSizeMake(ceil(ts.width + pad * 2), ceil(ts.height + pad * 2));
    CGFloat scale = [UIScreen mainScreen].scale;

    // 1) Máscara do texto
    size_t mw = (size_t)(canvas.width * scale), mh = (size_t)(canvas.height * scale);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef mctx = CGBitmapContextCreate(NULL, mw, mh, 8, mw, gray, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    CGContextSetGrayFillColor(mctx, 0, 1);
    CGContextFillRect(mctx, CGRectMake(0, 0, mw, mh));
    CGContextTranslateCTM(mctx, 0, mh);
    CGContextScaleCTM(mctx, scale, -scale);
    UIGraphicsPushContext(mctx);
    [text drawAtPoint:CGPointMake(pad, pad) withAttributes:attrs];
    UIGraphicsPopContext();
    CGImageRef mask = CGBitmapContextCreateImage(mctx);
    CGContextRelease(mctx);

    UIGraphicsBeginImageContextWithOptions(canvas, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // 2) Contorno escuro com sombra
    NSDictionary *strokeAttrs = @{NSFontAttributeName: font,
                                  NSStrokeColorAttributeName: [UIColor colorWithWhite:0.02 alpha:1],
                                  NSStrokeWidthAttributeName: @(size > 40 ? 9 : 6)};
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, size * 0.04), size * 0.08, [UIColor colorWithRed:0.24 green:0.56 blue:1.0 alpha:0.55].CGColor);
    [text drawAtPoint:CGPointMake(pad, pad) withAttributes:strokeAttrs];
    CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);

    // 3) Prata: claro em cima, linha escura no meio (horizonte do reflexo), claro embaixo
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0, canvas.height);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextClipToMask(ctx, CGRectMake(0, 0, canvas.width, canvas.height), mask);
    CGFloat comps[] = {
        0.98, 0.98, 1.00, 1,
        0.78, 0.80, 0.86, 1,
        0.38, 0.40, 0.46, 1,
        0.86, 0.88, 0.94, 1,
        0.62, 0.64, 0.70, 1,
    };
    CGFloat locs[] = {0.0, 0.42, 0.52, 0.62, 1.0};
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColorComponents(rgb, comps, locs, 5);
    CGColorSpaceRelease(rgb);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(0, canvas.height - pad), CGPointMake(0, pad), 0);
    CGGradientRelease(g);
    CGContextRestoreGState(ctx);
    CGImageRelease(mask);

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

void RFThemeApplyNavigationBar(UINavigationBar *bar) {
    bar.barStyle = UIBarStyleBlack;
    bar.barTintColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.06 alpha:1];
    bar.translucent = NO;
    bar.tintColor = RFThemeRed();
    bar.titleTextAttributes = @{NSFontAttributeName: RFThemeDisplayFont(22), NSForegroundColorAttributeName: RFThemeText()};
}

// Tabelas agrupadas (telas de Controle): fundo grafite e células escuras
void RFThemeApplyTable(UITableView *table) {
    table.backgroundView = RFThemeGridView();
    table.backgroundColor = [UIColor colorWithRed:0.095 green:0.095 blue:0.11 alpha:1];
    table.separatorColor = [UIColor colorWithWhite:0.22 alpha:1];
    table.indicatorStyle = UIScrollViewIndicatorStyleWhite;
}

void RFThemeStyleCell(UITableViewCell *cell) {
    cell.backgroundColor = RFThemeCard();
    UIColor *c = cell.textLabel.textColor;
    if (!c || [c isEqual:[UIColor blackColor]]) cell.textLabel.textColor = RFThemeText();
    cell.detailTextLabel.textColor = RFThemeDim();
    UIView *sel = [[UIView alloc] init];
    sel.backgroundColor = [RFThemeRed() colorWithAlphaComponent:0.35];
    cell.selectedBackgroundView = sel;
}

void RFThemeStyleHeaderFooter(UIView *view, BOOL header) {
    if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
    UITableViewHeaderFooterView *v = (UITableViewHeaderFooterView *)view;
    v.textLabel.textColor = header ? RFThemeRed() : RFThemeDim();
    if (header) v.textLabel.font = RFThemeLabelFont(13);
}
