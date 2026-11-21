#import "RF.h"
#include "libretro.h"
#include "rc_consoles.h"
#import <QuartzCore/QuartzCore.h>
#include <stdarg.h>

volatile uint32_t rf_touch_mask = 0;
volatile uint32_t rf_pad_mask = 0;
volatile int16_t rf_analog[4] = {0, 0, 0, 0};
volatile double rf_input_changed_at = 0;
volatile uint32_t rf_input_seq = 0;

void RFInputChanged(void) {
    rf_input_changed_at = CACurrentMediaTime();
    rf_input_seq++;
}

NSString *RFBaseDir(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *base = [docs stringByAppendingPathComponent:@"PSX32"];
    [[NSFileManager defaultManager] createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    return base;
}

void RFAppendLog(NSString *file, NSString *line) {
    @synchronized ([NSFileManager class]) {
    static NSDateFormatter *fmt;
    if (!fmt) {
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    }
    NSString *path = [RFBaseDir() stringByAppendingPathComponent:file];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attrs fileSize] > 200 * 1024) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSString *text = [NSString stringWithFormat:@"%@  %@\n", [fmt stringFromDate:[NSDate date]], line];
    FILE *f = fopen(path.fileSystemRepresentation, "a");
    if (!f) return;
    fputs(text.UTF8String, f);
    fclose(f);
    }
}

NSString *RFDir(NSString *name) {
    NSString *dir = [RFBaseDir() stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

#pragma mark - Callbacks do libretro

static char rf_system_dir[1024];
static char rf_save_dir[1024];

static const void *rf_frame_data = NULL;
static unsigned rf_frame_width = 0, rf_frame_height = 0;
static size_t rf_frame_pitch = 0;
static float rf_aspect = 4.0f / 3.0f;
static bool rf_skip_video = false;
static bool rf_mute_audio = false;
static bool rf_fast_states = false;

static struct retro_disk_control_callback rf_disk;
static bool rf_has_disk = false;

// Opções do core que o PSX32 fixa (o resto fica no padrão do PCSX ReARMed)
static bool rf_boot_logo = true;   // com BIOS de verdade: mostra a abertura do console antes do jogo

static const char *rf_option(const char *key) {
    if (!strcmp(key, "pcsx_rearmed_show_bios_bootlogo")) return rf_boot_logo ? "enabled" : "disabled";
    static const char *const opts[][2] = {
        {"pcsx_rearmed_drc", "enabled"},                 // recompilador dinâmico (JIT)
        {"pcsx_rearmed_bios", "auto"},                   // BIOS real se houver, senão HLE

        {"pcsx_rearmed_frameskip_type", "disabled"},     // o ritmo pelo áudio já cuida disso
        {"pcsx_rearmed_spu_interpolation", "simple"},
        {"pcsx_rearmed_spu_thread", "enabled"},             // som do PS1 em outra thread (o A5X tem 2 núcleos)
        {"pcsx_rearmed_gpu_thread_rendering", "enabled"},   // vídeo do PS1 em outra thread
        {"pcsx_rearmed_neon_enhancement_enable", "disabled"},   // resolução nativa: o A5X não aguenta 2x
        {"pcsx_rearmed_memcard1", "libretro"},   // cartão 1 entregue ao app (.srm); sem isso o core fica sem cartão
        {"pcsx_rearmed_memcard2", "none"},
    };
    for (size_t i = 0; i < sizeof(opts) / sizeof(opts[0]); i++) {
        if (!strcmp(opts[i][0], key)) return opts[i][1];
    }
    return NULL;
}

static void rf_core_log(enum retro_log_level level, const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    size_t n = strlen(buf);
    while (n && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
    NSString *line = [NSString stringWithUTF8String:buf] ?: @"(invalid text)";
    RFAppendLog(@"core.txt", line);
}

static bool rf_environment(unsigned cmd, void *data) {
    switch (cmd) {
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            return *(const enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_RGB565;
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            *(const char **)data = rf_system_dir;
            return true;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            *(const char **)data = rf_save_dir;
            return true;
        case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
            return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            *(bool *)data = true;
            return true;
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            ((struct retro_log_callback *)data)->log = rf_core_log;
            return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            struct retro_variable *var = data;
            const char *v = var->key ? rf_option(var->key) : NULL;
            var->value = v;
            return v != NULL;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            *(bool *)data = false;
            return true;
        case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION:
            *(unsigned *)data = 0;   // usamos a interface simples
            return true;
        case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
            rf_disk = *(const struct retro_disk_control_callback *)data;
            rf_has_disk = true;
            return true;
        case RETRO_ENVIRONMENT_SET_GEOMETRY: {
            const struct retro_game_geometry *g = data;
            if (g->aspect_ratio > 0) rf_aspect = g->aspect_ratio;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
            const struct retro_system_av_info *av = data;
            if (av->geometry.aspect_ratio > 0) rf_aspect = av->geometry.aspect_ratio;
            return true;
        }
        case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
            RFAchievementsSetMemoryMap(data);   // RetroAchievements lê a RAM do jogo por este mapa
            return true;
        case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
            return true;
        case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
            // bit 0 = vídeo, bit 1 = áudio; bit 2 = "estados rápidos"
            *(int *)data = (rf_skip_video ? 2 : 3) | (rf_fast_states ? 4 : 0);
            return true;
        default:
            return false;
    }
}

static void rf_video_refresh(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!data) return;   // quadro repetido
    rf_frame_data = data;
    rf_frame_width = width;
    rf_frame_height = height;
    rf_frame_pitch = pitch;
}

static void rf_audio_sample(int16_t left, int16_t right) {
    if (rf_mute_audio) return;
    int16_t s[2] = {left, right};
    [[RFAudio shared] pushSamples:s frames:1];
}

static size_t rf_audio_sample_batch(const int16_t *data, size_t frames) {
    if (rf_mute_audio) return frames;
    [[RFAudio shared] pushSamples:data frames:frames];
    return frames;
}

static void rf_input_poll(void) {
}

static int16_t rf_input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port != 0) return 0;
    device &= RETRO_DEVICE_MASK;
    if (device == RETRO_DEVICE_JOYPAD) {
        uint32_t mask = rf_touch_mask | rf_pad_mask;
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)(mask & 0xFFFF);
        return (mask >> id) & 1;
    }
    if (device == RETRO_DEVICE_ANALOG && index <= RETRO_DEVICE_INDEX_ANALOG_RIGHT && id <= RETRO_DEVICE_ID_ANALOG_Y) {
        return rf_analog[index * 2 + id];
    }
    return 0;
}

#pragma mark - RFCore

@interface RFCore ()
@property (nonatomic, readwrite) double fps;
@property (nonatomic, readwrite) double sampleRate;
@property (nonatomic, readwrite) BOOL loaded;
@property (nonatomic, readwrite, copy) NSString *gameName;
@property (nonatomic, assign) BOOL initialized;
@property (nonatomic, readwrite) BOOL usingSharedCard;
@property (nonatomic, strong) NSMutableData *cardSnapshot;
@property (nonatomic, assign) BOOL cardDirty;
@property (nonatomic, strong) dispatch_source_t cardTimer;
@property (nonatomic, copy) NSString *gamePath;
@end

uint32_t RFConsoleForPath(NSString *path) {
    return RC_CONSOLE_PLAYSTATION;
}

NSArray *RFAchievementsConsoles(void) {
    return @[ @{ @"id": @(RC_CONSOLE_PLAYSTATION), @"name": @"PlayStation" } ];
}

@implementation RFCore

+ (instancetype)shared {
    static RFCore *core;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ core = [[RFCore alloc] init]; });
    return core;
}

- (float)aspectRatio {
    return rf_aspect;
}

- (void)ensureInit {
    if (self.initialized) return;
    strlcpy(rf_system_dir, RFDir(@"bios").fileSystemRepresentation, sizeof(rf_system_dir));
    strlcpy(rf_save_dir, RFDir(@"saves").fileSystemRepresentation, sizeof(rf_save_dir));
    retro_set_environment(rf_environment);
    retro_set_video_refresh(rf_video_refresh);
    retro_set_audio_sample(rf_audio_sample);
    retro_set_audio_sample_batch(rf_audio_sample_batch);
    retro_set_input_poll(rf_input_poll);
    retro_set_input_state(rf_input_state);
    retro_init();
    self.initialized = YES;
}

+ (NSString *)cardPathForGame:(NSString *)game shared:(BOOL)shared {
    NSString *name = shared ? @"Shared memory card" : game;
    return [RFDir(@"saves") stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"srm"]];
}

- (NSString *)sramPath {
    return [RFCore cardPathForGame:self.gameName shared:self.usingSharedCard];
}

// Fila só para gravar o cartão sem atrasar quadros
static dispatch_queue_t rf_card_queue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("psx32.memcard", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static void rf_write_card(NSData *data, NSString *path) {
    dispatch_async(rf_card_queue(), ^{ [data writeToFile:path atomically:YES]; });
}

- (NSData *)liveCard {
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *mem = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!self.loaded || !mem || !size) return nil;
    return [NSData dataWithBytes:mem length:size];
}

- (void)replaceLiveCard:(NSData *)card {
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *mem = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!self.loaded || !mem || !size || !card) return;
    memcpy(mem, card.bytes, MIN(size, card.length));
    self.cardSnapshot = [NSMutableData dataWithBytes:mem length:size];
    self.cardDirty = NO;
    rf_write_card([self.cardSnapshot copy], [self sramPath]);
}

// Coloca no slot o cartão salvo (ou um cartão novo, formatado)
- (void)insertCard {
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *mem = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!mem || !size) return;
    NSData *card = [NSData dataWithContentsOfFile:[self sramPath]];
    if (card.length < size) card = RFMemoryCardBlank();
    memcpy(mem, card.bytes, MIN(size, card.length));
    self.cardSnapshot = [NSMutableData dataWithBytes:mem length:size];
    self.cardDirty = NO;
}

- (void)useSharedCard:(BOOL)shared {
    if (!self.loaded || shared == self.usingSharedCard) return;
    [self saveSRAM];
    dispatch_sync(rf_card_queue(), ^{});
    self.usingSharedCard = shared;
    [[NSUserDefaults standardUserDefaults] setBool:shared forKey:@"RFSharedCard"];
    [self insertCard];
    retro_reset();
    [[RFAchievements shared] reset];
}

// A cada segundo: se o jogo mexeu no cartão e ele parou de mudar, grava (como o console grava na hora)
- (void)pollCard {
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *mem = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!self.loaded || !mem || !size) return;
    if (self.cardSnapshot.length != size) {
        self.cardSnapshot = [NSMutableData dataWithBytes:mem length:size];
        return;
    }
    if (memcmp(mem, self.cardSnapshot.bytes, size) != 0) {
        memcpy(self.cardSnapshot.mutableBytes, mem, size);
        self.cardDirty = YES;
        return;
    }
    if (self.cardDirty) {
        self.cardDirty = NO;
        rf_write_card([self.cardSnapshot copy], [self sramPath]);
    }
}

- (NSString *)statePath:(int)slot {
    NSString *file = [NSString stringWithFormat:@"%@.state%d", self.gameName, slot];
    return [RFDir(@"states") stringByAppendingPathComponent:file];
}

// Linhas "FILE "nome.bin" BINARY" de um .cue, ou as linhas de um .m3u
static NSArray<NSString *> *rf_referenced_files(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
                  ?: [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:nil];
    if (!text) return @[];
    NSString *ext = path.pathExtension.lowercaseString;
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *name = nil;
        if ([ext isEqualToString:@"cue"]) {
            if (![line.uppercaseString hasPrefix:@"FILE "]) continue;
            NSRange q1 = [line rangeOfString:@"\""];
            NSRange q2 = q1.location == NSNotFound ? q1 : [line rangeOfString:@"\"" options:NSBackwardsSearch];
            if (q1.location != NSNotFound && q2.location > q1.location) {
                name = [line substringWithRange:NSMakeRange(q1.location + 1, q2.location - q1.location - 1)];
            } else {
                NSArray *parts = [line componentsSeparatedByString:@" "];
                if (parts.count >= 2) name = parts[1];
            }
        } else {
            if (!line.length || [line hasPrefix:@"#"]) continue;
            name = line;
        }
        if (name.length) [out addObject:[dir stringByAppendingPathComponent:name.lastPathComponent]];
    }
    return out;
}

+ (NSArray<NSString *> *)filesForGame:(NSString *)path {
    NSMutableArray *files = [NSMutableArray arrayWithObject:path];
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"cue"] || [ext isEqualToString:@"m3u"]) {
        for (NSString *f in rf_referenced_files(path)) {
            if ([files containsObject:f]) continue;
            [files addObject:f];
            if ([f.pathExtension.lowercaseString isEqualToString:@"cue"]) {
                for (NSString *g in rf_referenced_files(f)) if (![files containsObject:g]) [files addObject:g];
            }
        }
    }
    if ([ext isEqualToString:@"ccd"] || [ext isEqualToString:@"img"]) {
        NSString *base = path.stringByDeletingPathExtension;
        for (NSString *e in @[@"ccd", @"img", @"sub"]) {
            NSString *f = [base stringByAppendingPathExtension:e];
            if (![files containsObject:f] && [[NSFileManager defaultManager] fileExistsAtPath:f]) [files addObject:f];
        }
    }
    return files;
}

+ (NSString *)biosName {
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:RFDir(@"bios") error:nil]) {
        NSString *lower = f.lowercaseString;
        if (([lower hasPrefix:@"scph"] || [lower hasPrefix:@"psxonpsp"] || [lower hasPrefix:@"ps1_rom"]) &&
            [lower.pathExtension isEqualToString:@"bin"]) return f;
    }
    return nil;
}

- (void)applyController {
    // Controle digital (padrão, compatível com tudo) ou DualShock com os dois analógicos
    unsigned device = self.dualShock ? RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, 1)
                                     : RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD, 0);
    retro_set_controller_port_device(0, device);
}

- (void)setDualShock:(BOOL)dualShock {
    _dualShock = dualShock;
    if (self.loaded) [self applyController];
}

- (BOOL)loadGameAtPath:(NSString *)path error:(NSString **)error {
    NSNumber *pref = [[NSUserDefaults standardUserDefaults] objectForKey:@"RFBootLogo"];
    rf_boot_logo = pref ? pref.boolValue : true;
    [self ensureInit];   // o core registra a troca de discos em retro_init
    if (self.loaded) [self unload];

    for (NSString *f in [RFCore filesForGame:path]) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:f]) {
            if (error) *error = [NSString stringWithFormat:@"%@ needs the file \"%@\", which is not on the iPad. Upload it too (same name, same folder).",
                                 path.lastPathComponent, f.lastPathComponent];
            return NO;
        }
    }
    RFAppendLog(@"core.txt", [NSString stringWithFormat:@"--- loading %@", path.lastPathComponent]);

    struct retro_game_info info;
    memset(&info, 0, sizeof(info));
    info.path = path.fileSystemRepresentation;
    if (!retro_load_game(&info)) {
        if (error) *error = @"The emulator could not load this disc image. Check that all of its files (.cue + .bin tracks) were uploaded, or try a .chd/.pbp version.";
        return NO;
    }

    struct retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    retro_get_system_av_info(&av);
    self.fps = av.timing.fps > 0 ? av.timing.fps : 60.0;
    self.sampleRate = av.timing.sample_rate > 0 ? av.timing.sample_rate : 44100.0;
    if (av.geometry.aspect_ratio > 0) rf_aspect = av.geometry.aspect_ratio;
    else rf_aspect = 4.0f / 3.0f;

    self.gameName = path.lastPathComponent.stringByDeletingPathExtension;
    self.loaded = YES;
    rf_frame_data = NULL;
    [self applyController];

    // Restaura o memory card (o core expõe o cartão 1 como "SRAM")
    self.usingSharedCard = [[NSUserDefaults standardUserDefaults] boolForKey:@"RFSharedCard"];
    NSData *sram = [NSData dataWithContentsOfFile:[self sramPath]];
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *mem = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (sram && mem && size) {
        memcpy(mem, sram.bytes, MIN(size, sram.length));
    }
    self.cardSnapshot = mem && size ? [NSMutableData dataWithBytes:mem length:size] : nil;
    self.cardDirty = NO;
    if (self.cardTimer) dispatch_source_cancel(self.cardTimer);
    self.cardTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.cardTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    __weak RFCore *weakSelf = self;
    dispatch_source_set_event_handler(self.cardTimer, ^{ [weakSelf pollCard]; });
    dispatch_resume(self.cardTimer);
    self.gamePath = path;
    [[RFAchievements shared] gameLoadedAtPath:path console:RFConsoleForPath(path) patched:NO];
    return YES;
}

- (NSUInteger)discCount {
    if (!self.loaded || !rf_has_disk || !rf_disk.get_num_images) return 0;
    return rf_disk.get_num_images();
}

- (NSUInteger)currentDisc {
    if (!self.loaded || !rf_has_disk || !rf_disk.get_image_index) return 0;
    return rf_disk.get_image_index();
}

- (BOOL)switchToDisc:(NSUInteger)index {
    if (index >= self.discCount || !rf_disk.set_eject_state || !rf_disk.set_image_index) return NO;
    // Abre a tampa, troca o disco e fecha, como no console
    if (!rf_disk.set_eject_state(true)) return NO;
    BOOL ok = rf_disk.set_image_index((unsigned)index);
    rf_disk.set_eject_state(false);
    // RetroAchievements: confere o disco novo (só dá para saber o arquivo quando o jogo é um .m3u)
    if (ok && [self.gamePath.pathExtension.lowercaseString isEqualToString:@"m3u"]) {
        NSArray *discs = rf_referenced_files(self.gamePath);
        if (index < discs.count) [[RFAchievements shared] changeMediaToPath:discs[index]];
    }
    return ok;
}

- (void)runFrame {
    [self runFrameSkippingVideo:NO];
}

- (void)runFrameSkippingVideo:(BOOL)skip {
    if (!self.loaded) return;
    rf_skip_video = skip;
    retro_run();
    rf_skip_video = false;
    if (!rf_mute_audio) [[RFAchievements shared] doFrame];   // quadros previstos do run-ahead não contam
}

static void *rf_ahead_state = NULL;
static size_t rf_ahead_size = 0;

- (BOOL)runFrameWithRunAhead {
    if (!self.loaded) return NO;
    size_t size = retro_serialize_size();
    if (!size) {
        [self runFrameSkippingVideo:NO];
        return NO;
    }
    if (size > rf_ahead_size) {
        free(rf_ahead_state);
        rf_ahead_state = malloc(size);
        rf_ahead_size = rf_ahead_state ? size : 0;
    }
    [self runFrameSkippingVideo:YES];
    rf_fast_states = true;
    BOOL saved = rf_ahead_state && retro_serialize(rf_ahead_state, size);
    rf_fast_states = false;
    if (!saved) return NO;
    rf_mute_audio = true;
    [self runFrameSkippingVideo:NO];
    rf_mute_audio = false;
    rf_fast_states = true;
    retro_unserialize(rf_ahead_state, size);
    rf_fast_states = false;
    return YES;
}

- (void)reset {
    if (!self.loaded) return;
    retro_reset();
    [[RFAchievements shared] reset];
}

- (void)saveSRAM {
    if (!self.loaded) return;
    size_t size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void *mem = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!mem || !size) return;
    // Cartão sem nenhum save e sem arquivo ainda: não cria arquivo à toa
    NSString *path = [self sramPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path] && !RFMemoryCardHasSaves(mem, size)) return;
    NSData *data = [NSData dataWithBytes:mem length:size];
    self.cardSnapshot = [data mutableCopy];
    self.cardDirty = NO;
    dispatch_sync(rf_card_queue(), ^{ [data writeToFile:path atomically:YES]; });
}

- (void)unload {
    if (!self.loaded) return;
    [self saveSRAM];
    if (self.cardTimer) {
        dispatch_source_cancel(self.cardTimer);
        self.cardTimer = nil;
    }
    [[RFAchievements shared] gameUnloaded];
    retro_unload_game();
    self.loaded = NO;
    rf_frame_data = NULL;
}

- (BOOL)saveStateSlot:(int)slot {
    if (!self.loaded) return NO;
    size_t size = retro_serialize_size();
    if (!size) return NO;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (!retro_serialize(data.mutableBytes, size)) return NO;
    // Estado das conquistas junto (para não disparar ou perder conquistas ao carregar)
    NSString *raPath = [[self statePath:slot] stringByAppendingString:@".ra"];
    NSData *progress = [[RFAchievements shared] progress];
    if (progress) [progress writeToFile:raPath atomically:YES];
    else [[NSFileManager defaultManager] removeItemAtPath:raPath error:nil];
    return [data writeToFile:[self statePath:slot] atomically:YES];
}

- (BOOL)loadStateSlot:(int)slot {
    if (!self.loaded) return NO;
    NSData *data = [NSData dataWithContentsOfFile:[self statePath:slot]];
    if (!data) return NO;
    if (!retro_unserialize(data.bytes, data.length)) return NO;
    [[RFAchievements shared] restoreProgress:[NSData dataWithContentsOfFile:[[self statePath:slot] stringByAppendingString:@".ra"]]];
    return YES;
}

- (NSDate *)dateForStateSlot:(int)slot {
    if (!self.loaded) return nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:[self statePath:slot] error:nil];
    return attrs.fileModificationDate;
}

- (BOOL)hasStateSlot:(int)slot {
    return self.loaded && [[NSFileManager defaultManager] fileExistsAtPath:[self statePath:slot]];
}

- (const void *)frameData:(unsigned *)width height:(unsigned *)height pitch:(size_t *)pitch {
    if (width) *width = rf_frame_width;
    if (height) *height = rf_frame_height;
    if (pitch) *pitch = rf_frame_pitch;
    return rf_frame_data;
}

@end

#pragma mark - Áudio (RemoteIO + buffer circular)

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#define RF_RING_FRAMES 16384   // ~370 ms a 44,1 kHz
static int16_t rf_ring[RF_RING_FRAMES * 2];
static volatile uint32_t rf_ring_write = 0;   // em quadros (estéreo)
static volatile uint32_t rf_ring_read = 0;
static volatile uint32_t rf_underruns = 0;
static volatile int rf_audio_primed = 0;   // só conta falhas depois que o som começou

static OSStatus rf_render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 frames, AudioBufferList *io) {
    int16_t *out = io->mBuffers[0].mData;
    uint32_t r = rf_ring_read;
    uint32_t w = rf_ring_write;
    __sync_synchronize();
    uint32_t available = w - r;
    uint32_t n = MIN(available, frames);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (r + i) % RF_RING_FRAMES;
        out[i * 2] = rf_ring[idx * 2];
        out[i * 2 + 1] = rf_ring[idx * 2 + 1];
    }
    if (n < frames) {
        memset(out + n * 2, 0, (frames - n) * 4);   // faltou som: silêncio
        if (rf_audio_primed) rf_underruns++;
    } else {
        rf_audio_primed = 1;
    }
    __sync_synchronize();
    rf_ring_read = r + n;
    return noErr;
}

@interface RFAudio ()
@property (nonatomic, assign) AudioComponentInstance unit;
@property (nonatomic, assign) BOOL running;
@end

@implementation RFAudio

+ (instancetype)shared {
    static RFAudio *audio;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ audio = [[RFAudio alloc] init]; });
    return audio;
}

- (void)startWithSampleRate:(double)rate {
    [self stop];
    [self clear];
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setPreferredIOBufferDuration:0.012 error:nil];
    [session setActive:YES error:nil];

    AudioComponentDescription desc = {0};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    AudioComponentInstance unit = NULL;
    if (!comp || AudioComponentInstanceNew(comp, &unit) != noErr) return;

    AudioStreamBasicDescription fmt = {0};
    fmt.mSampleRate = rate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel = 16;
    fmt.mBytesPerFrame = 4;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = 4;
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));

    AURenderCallbackStruct cb = { rf_render, NULL };
    AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));

    if (AudioUnitInitialize(unit) == noErr && AudioOutputUnitStart(unit) == noErr) {
        self.unit = unit;
        self.running = YES;
    } else {
        AudioComponentInstanceDispose(unit);
    }
}

- (void)stop {
    if (!self.unit) return;
    AudioOutputUnitStop(self.unit);
    AudioUnitUninitialize(self.unit);
    AudioComponentInstanceDispose(self.unit);
    self.unit = NULL;
    self.running = NO;
}

- (void)clear {
    rf_ring_read = 0;
    rf_ring_write = 0;
    rf_audio_primed = 0;
}

- (uint32_t)bufferedFrames {
    uint32_t w = rf_ring_write;
    uint32_t r = rf_ring_read;
    return w - r;
}

- (uint32_t)underruns {
    return rf_underruns;
}

- (void)pushSamples:(const int16_t *)data frames:(size_t)frames {
    uint32_t w = rf_ring_write;
    uint32_t r = rf_ring_read;
    uint32_t used = w - r;
    // Mantém a latência baixa: se o buffer encher demais, descarta o excesso
    uint32_t limit = RF_RING_FRAMES / 2;   // o ritmo do jogo já segura a fila; isto é só proteção
    if (used > limit) return;
    uint32_t space = RF_RING_FRAMES - used;
    uint32_t n = (uint32_t)MIN(frames, space);
    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (w + i) % RF_RING_FRAMES;
        rf_ring[idx * 2] = data[i * 2];
        rf_ring[idx * 2 + 1] = data[i * 2 + 1];
    }
    __sync_synchronize();
    rf_ring_write = w + n;
}

@end
