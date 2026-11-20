// Memory cards do PSX32: leitura do formato do cartão do PlayStation (128 KB, 16 blocos de 8 KB)
// e a tela de gerenciamento no estilo da tela de memory card do console: dois cartões lado a lado
// (o do jogo e o compartilhado), 15 blocos cada, ícones animados, copiar e apagar saves.

#import "RF.h"
#import <QuartzCore/QuartzCore.h>

#define RF_CARD_SIZE 0x20000
#define RF_BLOCK 0x2000
#define RF_FRAME 0x80

#pragma mark - Formato do cartão

static void rf_card_checksum(uint8_t *frame) {
    uint8_t x = 0;
    for (int i = 0; i < 0x7F; i++) x ^= frame[i];
    frame[0x7F] = x;
}

// Cartão formatado e vazio, igual ao que o console grava ao formatar
NSData *RFMemoryCardBlank(void) {
    NSMutableData *d = [NSMutableData dataWithLength:RF_CARD_SIZE];
    uint8_t *p = d.mutableBytes;
    p[0] = 'M'; p[1] = 'C';
    rf_card_checksum(p);
    for (int i = 1; i < 16; i++) {
        uint8_t *f = p + i * RF_FRAME;
        f[0] = 0xA0;
        f[8] = 0xFF; f[9] = 0xFF;
        rf_card_checksum(f);
    }
    for (int i = 16; i < 36; i++) {   // lista de setores defeituosos: nenhum
        uint8_t *f = p + i * RF_FRAME;
        memset(f, 0xFF, 4);
        f[8] = 0xFF; f[9] = 0xFF;
        rf_card_checksum(f);
    }
    memcpy(p + 63 * RF_FRAME, p, RF_FRAME);
    return d;
}

BOOL RFMemoryCardHasSaves(const void *bytes, size_t length) {
    const uint8_t *p = bytes;
    if (length < RF_BLOCK) return NO;
    for (int i = 1; i < 16; i++) {
        uint8_t s = p[i * RF_FRAME];
        if (s == 0x51 || s == 0x52 || s == 0x53) return YES;
    }
    return NO;
}

static BOOL rf_card_valid(NSData *d) {
    return d.length >= RF_CARD_SIZE && ((const uint8_t *)d.bytes)[0] == 'M' && ((const uint8_t *)d.bytes)[1] == 'C';
}

@interface RFCardSave : NSObject
@property (nonatomic, strong) NSArray<NSNumber *> *blocks;   // blocos 1..15, na ordem
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, strong) NSArray<UIImage *> *icons;
@end

@implementation RFCardSave
@end

static UIImage *rf_icon_image(const uint8_t *pixels, const uint16_t *palette) {
    uint32_t rgba[256];
    for (int i = 0; i < 256; i++) {
        uint8_t v = pixels[i / 2];
        int idx = (i & 1) ? (v >> 4) : (v & 0x0F);
        uint16_t c = palette[idx];
        if (c == 0) { rgba[i] = 0; continue; }
        uint32_t r = (c & 31) * 255 / 31, g = ((c >> 5) & 31) * 255 / 31, b = ((c >> 10) & 31) * 255 / 31;
        rgba[i] = r | (g << 8) | (b << 16) | 0xFF000000u;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba, 16, 16, 8, 64, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    UIImage *ui = [UIImage imageWithCGImage:img];
    CGImageRelease(img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return ui;
}

static NSString *rf_card_title(const uint8_t *bytes) {
    int n = 0;
    while (n < 64 && bytes[n]) n++;
    NSString *s = [[NSString alloc] initWithBytes:bytes length:n encoding:NSShiftJISStringEncoding];
    if (!s) return @"";
    NSMutableString *m = [s mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformFullwidthHalfwidth, false);
    [m replaceOccurrencesOfString:@"　" withString:@" " options:0 range:NSMakeRange(0, m.length)];
    while ([m containsString:@"  "]) [m replaceOccurrencesOfString:@"  " withString:@" " options:0 range:NSMakeRange(0, m.length)];
    return [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static NSArray<RFCardSave *> *rf_card_saves(NSData *card) {
    NSMutableArray *list = [NSMutableArray array];
    if (!rf_card_valid(card)) return list;
    const uint8_t *p = card.bytes;
    for (int i = 1; i < 16; i++) {
        const uint8_t *f = p + i * RF_FRAME;
        if (f[0] != 0x51) continue;
        RFCardSave *save = [RFCardSave new];
        NSMutableArray *blocks = [NSMutableArray arrayWithObject:@(i)];
        int b = i;
        for (int guard = 0; guard < 15; guard++) {
            uint16_t next = p[b * RF_FRAME + 8] | (p[b * RF_FRAME + 9] << 8);
            if (next == 0xFFFF || next > 14) break;
            b = next + 1;
            if ([blocks containsObject:@(b)]) break;
            [blocks addObject:@(b)];
        }
        save.blocks = blocks;
        char name[21] = {0};
        memcpy(name, f + 0x0A, 20);
        save.fileName = [NSString stringWithCString:name encoding:NSASCIIStringEncoding] ?: @"";
        const uint8_t *t = p + i * RF_BLOCK;
        NSMutableArray *icons = [NSMutableArray array];
        if (t[0] == 'S' && t[1] == 'C') {
            save.title = rf_card_title(t + 4);
            int frames = t[2] == 0x13 ? 3 : t[2] == 0x12 ? 2 : 1;
            uint16_t palette[16];
            for (int c = 0; c < 16; c++) palette[c] = t[0x60 + c * 2] | (t[0x61 + c * 2] << 8);
            for (int k = 0; k < frames; k++) [icons addObject:rf_icon_image(t + 0x80 + k * 0x80, palette)];
        }
        if (!save.title.length) save.title = save.fileName;
        save.icons = icons;
        [list addObject:save];
    }
    return list;
}

static void rf_card_delete(NSMutableData *card, RFCardSave *save) {
    uint8_t *p = card.mutableBytes;
    for (NSNumber *n in save.blocks) {
        uint8_t *f = p + n.intValue * RF_FRAME;
        if (f[0] >= 0x51 && f[0] <= 0x53) f[0] = f[0] - 0x51 + 0xA1;
        rf_card_checksum(f);
    }
}

// Copia um save para outro cartão (como a opção "copiar" do console). Devolve nil ou o motivo da falha.
static NSString *rf_card_copy(NSData *from, RFCardSave *save, NSMutableData *to) {
    if (!rf_card_valid(to)) [to setData:RFMemoryCardBlank()];
    for (RFCardSave *s in rf_card_saves(to)) {
        if ([s.fileName isEqualToString:save.fileName]) return @"The other card already has this save. Delete it there first.";
    }
    uint8_t *p = to.mutableBytes;
    NSMutableArray *free = [NSMutableArray array];
    for (int i = 1; i < 16 && free.count < save.blocks.count; i++) {
        uint8_t s = p[i * RF_FRAME];
        if (s == 0xA0 || s == 0xA1 || s == 0xA2 || s == 0xA3) [free addObject:@(i)];
    }
    if (free.count < save.blocks.count) {
        return [NSString stringWithFormat:@"Not enough free blocks on the other card (needs %lu).", (unsigned long)save.blocks.count];
    }
    const uint8_t *src = from.bytes;
    NSUInteger n = save.blocks.count;
    for (NSUInteger k = 0; k < n; k++) {
        int sb = [save.blocks[k] intValue], db = [free[k] intValue];
        uint8_t *f = p + db * RF_FRAME;
        memcpy(f, src + sb * RF_FRAME, RF_FRAME);
        f[0] = k == 0 ? 0x51 : (k == n - 1 ? 0x53 : 0x52);
        uint16_t next = k + 1 < n ? (uint16_t)([free[k + 1] intValue] - 1) : 0xFFFF;
        f[8] = next & 0xFF;
        f[9] = next >> 8;
        rf_card_checksum(f);
        memcpy(p + db * RF_BLOCK, src + sb * RF_BLOCK, RF_BLOCK);
    }
    return nil;
}

#pragma mark - Tela

@interface RFCardTile : UIView
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, assign) int card;
@property (nonatomic, assign) int block;
@end

@implementation RFCardTile
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
        self.layer.borderColor = [UIColor colorWithWhite:0.28 alpha:1].CGColor;
        self.layer.borderWidth = 1;
        self.layer.cornerRadius = 4;
        self.icon = [[UIImageView alloc] initWithFrame:CGRectInset(self.bounds, 8, 8)];
        self.icon.layer.magnificationFilter = kCAFilterNearest;
        self.icon.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:self.icon];
    }
    return self;
}
@end

@interface RFMemoryCardViewController : UIViewController
@property (nonatomic, copy) void (^onDone)(void);
@property (nonatomic, strong) NSMutableData *gameCard;
@property (nonatomic, strong) NSMutableData *sharedCard;
@property (nonatomic, strong) NSArray *saves;           // [cartão] -> NSArray<RFCardSave *>
@property (nonatomic, strong) NSMutableArray *tiles;    // [cartão] -> NSArray<RFCardTile *>
@property (nonatomic, strong) NSArray<UILabel *> *headers;
@property (nonatomic, strong) NSArray<UILabel *> *freeLabels;
@property (nonatomic, strong) UISegmentedControl *slotControl;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *dupButton;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, strong) UILabel *noteLabel;
@property (nonatomic, assign) int selCard;
@property (nonatomic, strong) RFCardSave *selSave;
@end

@implementation RFMemoryCardViewController

- (NSMutableData *)loadCard:(BOOL)shared {
    RFCore *core = [RFCore shared];
    NSData *d = shared == core.usingSharedCard ? [core liveCard] : [NSData dataWithContentsOfFile:[RFCore cardPathForGame:core.gameName shared:shared]];
    return rf_card_valid(d) ? [d mutableCopy] : [RFMemoryCardBlank() mutableCopy];
}

- (void)reloadCards {
    self.gameCard = [self loadCard:NO];
    self.sharedCard = [self loadCard:YES];
    self.saves = @[rf_card_saves(self.gameCard), rf_card_saves(self.sharedCard)];
}

- (NSMutableData *)cardData:(int)card {
    return card == 0 ? self.gameCard : self.sharedCard;
}

- (void)storeCard:(int)card {
    RFCore *core = [RFCore shared];
    BOOL shared = card == 1;
    NSMutableData *d = [self cardData:card];
    if (shared == core.usingSharedCard) {
        [core replaceLiveCard:d];
    } else {
        [d writeToFile:[RFCore cardPathForGame:core.gameName shared:shared] atomically:YES];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Memory Cards";
    [self.view addSubview:RFThemeGridView()];
    self.view.subviews.firstObject.frame = self.view.bounds;
    self.view.subviews.firstObject.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self action:@selector(done)];
    self.slotControl = [[UISegmentedControl alloc] initWithItems:@[@"This game's card", @"Shared card"]];
    self.slotControl.tintColor = RFThemeRed();
    self.slotControl.selectedSegmentIndex = [RFCore shared].usingSharedCard ? 1 : 0;
    [self.slotControl addTarget:self action:@selector(slotChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.slotControl];

    NSMutableArray *headers = [NSMutableArray array], *frees = [NSMutableArray array];
    self.tiles = [NSMutableArray array];
    for (int c = 0; c < 2; c++) {
        UILabel *h = [[UILabel alloc] init];
        h.font = RFThemeDisplayFont(22);
        h.textColor = RFThemeText();
        h.textAlignment = NSTextAlignmentCenter;
        h.adjustsFontSizeToFitWidth = YES;
        [self.view addSubview:h];
        [headers addObject:h];
        UILabel *fl = [[UILabel alloc] init];
        fl.font = RFThemeLabelFont(13);
        fl.textColor = RFThemeDim();
        fl.textAlignment = NSTextAlignmentCenter;
        [self.view addSubview:fl];
        [frees addObject:fl];
        NSMutableArray *row = [NSMutableArray array];
        for (int b = 1; b < 16; b++) {
            RFCardTile *t = [[RFCardTile alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
            t.card = c;
            t.block = b;
            [t addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tileTapped:)]];
            [self.view addSubview:t];
            [row addObject:t];
        }
        [self.tiles addObject:row];
    }
    self.headers = headers;
    self.freeLabels = frees;

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = RFThemeDisplayFont(24);
    self.titleLabel.textColor = RFThemeText();
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    [self.view addSubview:self.titleLabel];
    self.detailLabel = [[UILabel alloc] init];
    self.detailLabel.font = RFThemeLabelFont(14);
    self.detailLabel.textColor = RFThemeDim();
    self.detailLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.detailLabel];
    self.dupButton = [self makeButton:@"Copy" action:@selector(copySave)];
    self.deleteButton = [self makeButton:@"Delete" action:@selector(deleteSave)];
    self.noteLabel = [[UILabel alloc] init];
    self.noteLabel.font = RFThemeLabelFont(13);
    self.noteLabel.textColor = RFThemeDim();
    self.noteLabel.numberOfLines = 0;
    self.noteLabel.textAlignment = NSTextAlignmentCenter;
    self.noteLabel.text = @"The card in the slot is the one the game uses. Saves are written to the iPad a moment after the game saves.\n"
                          @"Tip: copy your saves to the shared card to use them in every game, like on the console.";
    [self.view addSubview:self.noteLabel];

    [self reloadCards];
    [self refresh];
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = RFThemeDisplayFont(18);
    b.tintColor = RFThemeText();
    b.backgroundColor = RFThemeCard();
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = RFThemeRed().CGColor;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
    return b;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width;
    CGFloat top = self.topLayoutGuide.length + 16;
    self.slotControl.frame = CGRectMake(floor((W - 360) / 2), top, 360, 30);
    CGFloat tile = 64, gap = 8;
    CGFloat panelW = 3 * tile + 2 * gap;
    CGFloat between = MIN(160, W - 2 * panelW - 40);
    CGFloat x0 = floor((W - 2 * panelW - between) / 2);
    CGFloat y = top + 52;
    for (int c = 0; c < 2; c++) {
        CGFloat px = x0 + c * (panelW + between);
        self.headers[c].frame = CGRectMake(px - 30, y, panelW + 60, 28);
        self.freeLabels[c].frame = CGRectMake(px - 30, y + 28, panelW + 60, 18);
        NSArray *row = self.tiles[c];
        for (int i = 0; i < 15; i++) {
            RFCardTile *t = row[i];
            t.frame = CGRectMake(px + (i % 3) * (tile + gap), y + 54 + (i / 3) * (tile + gap), tile, tile);
        }
    }
    CGFloat gridBottom = y + 54 + 5 * (tile + gap);
    CGFloat w = MIN(W - 40, 620);
    self.titleLabel.frame = CGRectMake(floor((W - w) / 2), gridBottom + 10, w, 32);
    self.detailLabel.frame = CGRectMake(floor((W - w) / 2), gridBottom + 42, w, 20);
    self.dupButton.frame = CGRectMake(floor(W / 2) - 210, gridBottom + 74, 200, 44);
    self.deleteButton.frame = CGRectMake(floor(W / 2) + 10, gridBottom + 74, 200, 44);
    self.noteLabel.frame = CGRectMake(floor((W - w) / 2), gridBottom + 128, w, 54);
}

- (void)refresh {
    BOOL sharedInSlot = [RFCore shared].usingSharedCard;
    NSString *game = [RFCore shared].gameName;
    for (int c = 0; c < 2; c++) {
        BOOL inSlot = (c == 1) == sharedInSlot;
        self.headers[c].text = [NSString stringWithFormat:@"%@%@", c == 0 ? @"CARD · THIS GAME" : @"CARD · SHARED", inSlot ? @"  ◆ IN SLOT" : @""];
        self.headers[c].textColor = inSlot ? RFThemeRed() : RFThemeText();
        NSArray *saves = self.saves[c];
        NSMutableDictionary *owner = [NSMutableDictionary dictionary];
        int used = 0;
        for (RFCardSave *s in saves) {
            for (NSNumber *b in s.blocks) owner[b] = s;
            used += (int)s.blocks.count;
        }
        self.freeLabels[c].text = c == 0 ? [NSString stringWithFormat:@"%@ · %d of 15 blocks free", game, 15 - used]
                                         : [NSString stringWithFormat:@"%d of 15 blocks free", 15 - used];
        for (RFCardTile *t in self.tiles[c]) {
            RFCardSave *s = owner[@(t.block)];
            BOOL first = s && [s.blocks.firstObject intValue] == t.block;
            [t.icon stopAnimating];
            t.icon.animationImages = nil;
            t.icon.image = nil;
            t.icon.alpha = 1;
            if (s && s.icons.count) {
                if (s.icons.count > 1) {
                    t.icon.animationImages = s.icons;
                    t.icon.animationDuration = 0.16 * s.icons.count;
                    [t.icon startAnimating];
                } else {
                    t.icon.image = s.icons.firstObject;
                }
                if (!first) t.icon.alpha = 0.3;   // blocos de continuação do mesmo save
            }
            BOOL selected = s && s == self.selSave && c == self.selCard;
            t.layer.borderColor = selected ? RFThemeRed().CGColor : [UIColor colorWithWhite:s ? 0.45 : 0.22 alpha:1].CGColor;
            t.layer.borderWidth = selected ? 3 : 1;
            t.backgroundColor = s ? [UIColor colorWithWhite:0.12 alpha:1] : [UIColor colorWithWhite:0.06 alpha:1];
        }
    }
    RFCardSave *s = self.selSave;
    self.dupButton.hidden = self.deleteButton.hidden = !s;
    if (s) {
        self.titleLabel.text = s.title;
        self.detailLabel.text = [NSString stringWithFormat:@"%lu block%@ · %@", (unsigned long)s.blocks.count,
                                 s.blocks.count == 1 ? @"" : @"s", s.fileName];
        [self.dupButton setTitle:self.selCard == 0 ? @"Copy to shared  →" : @"←  Copy to this game" forState:UIControlStateNormal];
    } else {
        self.titleLabel.text = @"Select a save";
        self.detailLabel.text = @"Tap a block to see the save, copy it to the other card or delete it";
    }
}

- (void)tileTapped:(UITapGestureRecognizer *)g {
    RFCardTile *t = (RFCardTile *)g.view;
    self.selSave = nil;
    for (RFCardSave *s in self.saves[t.card]) {
        if ([s.blocks containsObject:@(t.block)]) self.selSave = s;
    }
    self.selCard = t.card;
    [self refresh];
}

- (void)copySave {
    RFCardSave *s = self.selSave;
    if (!s) return;
    int to = 1 - self.selCard;
    NSString *err = rf_card_copy([self cardData:self.selCard], s, [self cardData:to]);
    if (err) {
        [self alert:@"Could not copy" message:err];
        return;
    }
    [self storeCard:to];
    [self reloadCards];
    self.selSave = nil;
    [self refresh];
}

- (void)deleteSave {
    RFCardSave *s = self.selSave;
    if (!s) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Delete save?"
        message:[NSString stringWithFormat:@"\"%@\" (%lu block%@) will be erased from this card.", s.title,
                 (unsigned long)s.blocks.count, s.blocks.count == 1 ? @"" : @"s"]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        rf_card_delete([self cardData:self.selCard], s);
        [self storeCard:self.selCard];
        [self reloadCards];
        self.selSave = nil;
        [self refresh];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)slotChanged {
    BOOL shared = self.slotControl.selectedSegmentIndex == 1;
    if (shared == [RFCore shared].usingSharedCard) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:shared ? @"Use the shared card?" : @"Use this game's card?"
        message:@"The game restarts with the other card in the slot, like swapping cards with the console off. Progress since your last save is lost."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
        self.slotControl.selectedSegmentIndex = shared ? 0 : 1;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Switch and restart" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [[RFCore shared] useSharedCard:shared];
        [self reloadCards];
        [self refresh];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)done {
    void (^cb)(void) = self.onDone;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(); }];
}

@end

UIViewController *RFMemoryCardController(void (^onDone)(void)) {
    RFMemoryCardViewController *vc = [RFMemoryCardViewController new];
    vc.onDone = onDone;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    RFThemeApplyNavigationBar(nav.navigationBar);
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    return nav;
}
