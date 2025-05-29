%config(generator=MobileSubstrate)
#import <AVFoundation/AVFoundation.h>
#import <MobileSubstrate/MobileSubstrate.h>
#import <CoreMedia/CoreMedia.h>
#import <MediaPlayer/MediaPlayer.h>
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <UIKit/UIKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>

// 全局变量
static BOOL g_cameraRunning = NO;
static AVPlayer *g_player = nil;
static AVPlayerItemVideoOutput *g_videoOutput = nil;
static VirtualCameraViewController *g_virtualCameraVC = nil;
static dispatch_source_t g_frameTimer = nil;
static CVPixelBufferRef g_currentPixelBuffer = nil;

@interface VirtualCameraViewController : UIViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) UIButton *selectVideoSourceButton;
@property (nonatomic, strong) UIButton *selectStreamSourceButton;
@property (nonatomic, strong) UIButton *setExifButton;
@property (nonatomic, strong) UIButton *startCameraButton;
@property (nonatomic, strong) UIButton *stopCameraButton;
@property (nonatomic, strong) NSString *selectedVideoSource;
@property (nonatomic, strong) NSString *streamURL;
@property (nonatomic, strong) NSURL *localVideoURL;
@property (nonatomic, strong) NSDictionary *customExifData;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *previewLayer;
@end

@implementation VirtualCameraViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self requestPermissions];
    [self setupUI];
    g_virtualCameraVC = self;
}

- (void)dealloc {
    [self cleanupResources];
}

- (void)cleanupResources {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (g_frameTimer) {
        dispatch_source_cancel(g_frameTimer);
        g_frameTimer = nil;
    }
    
    if (g_player) {
        [g_player pause];
        g_player = nil;
    }
    
    g_videoOutput = nil;
    
    if (self.previewLayer) {
        [self.previewLayer removeFromSuperlayer];
        self.previewLayer = nil;
    }
    
    if (g_currentPixelBuffer) {
        CVPixelBufferRelease(g_currentPixelBuffer);
        g_currentPixelBuffer = nil;
    }
    
    if (g_virtualCameraVC == self) {
        g_virtualCameraVC = nil;
    }
    
    g_cameraRunning = NO;
}

#pragma mark - 权限请求
- (void)requestPermissions {
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != PHAuthorizationStatusAuthorized) {
                [self showPermissionAlert:@"需要相册访问权限来选择视频源"];
            }
        });
    }];
    
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) {
                [self showPermissionAlert:@"需要相机权限来启用虚拟相机功能"];
            }
        });
    }];
}

- (void)showPermissionAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"权限提醒" 
                                                                   message:message 
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"去设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Setup UI
- (void)setupUI {
    self.view.backgroundColor = [UIColor whiteColor];
    
    self.selectVideoSourceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.selectVideoSourceButton setTitle:@"选择本地视频源" forState:UIControlStateNormal];
    self.selectVideoSourceButton.frame = CGRectMake(50, 100, 300, 50);
    [self.selectVideoSourceButton addTarget:self action:@selector(selectLocalVideoSource) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.selectVideoSourceButton];
    
    self.selectStreamSourceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.selectStreamSourceButton setTitle:@"选择流媒体源" forState:UIControlStateNormal];
    self.selectStreamSourceButton.frame = CGRectMake(50, 170, 300, 50);
    [self.selectStreamSourceButton addTarget:self action:@selector(selectStreamSource) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.selectStreamSourceButton];
    
    self.setExifButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.setExifButton setTitle:@"设置EXIF信息" forState:UIControlStateNormal];
    self.setExifButton.frame = CGRectMake(50, 240, 300, 50);
    [self.setExifButton addTarget:self action:@selector(setExifData) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.setExifButton];
    
    self.startCameraButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.startCameraButton setTitle:@"启动虚拟相机" forState:UIControlStateNormal];
    self.startCameraButton.frame = CGRectMake(50, 310, 300, 50);
    [self.startCameraButton addTarget:self action:@selector(startVirtualCamera) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.startCameraButton];
    
    self.stopCameraButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.stopCameraButton setTitle:@"关闭虚拟相机" forState:UIControlStateNormal];
    self.stopCameraButton.frame = CGRectMake(50, 380, 300, 50);
    [self.stopCameraButton addTarget:self action:@selector(stopVirtualCamera) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.stopCameraButton];
}

#pragma mark - 视频源选择逻辑
- (void)selectLocalVideoSource {
    self.selectedVideoSource = @"local";
    [self openPhotoLibraryForVideoSource];
}

- (void)selectStreamSource {
    self.selectedVideoSource = @"stream";
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"输入HLS流媒体URL" 
                                                                             message:nil 
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"http://your-server-ip/live/stream.m3u8";
    }];
    
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *urlField = alertController.textFields.firstObject;
        self.streamURL = urlField.text;
        NSLog(@"设置流媒体源 URL: %@", self.streamURL);
    }];
    
    [alertController addAction:confirmAction];
    [alertController addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)setExifData {
    [self openPhotoLibraryForExif];
}

#pragma mark - 启动/关闭虚拟相机
- (void)startVirtualCamera {
    if (g_cameraRunning) {
        [self showAlert:@"虚拟相机已在运行中"];
        return;
    }

    @try {
        if ([self.selectedVideoSource isEqualToString:@"local"]) {
            if (!self.localVideoURL) {
                [self showAlert:@"请先选择本地视频源"];
                return;
            }
            [self startLocalVideoPlayback];
        } else if ([self.selectedVideoSource isEqualToString:@"stream"]) {
            if (!self.streamURL || [self.streamURL length] == 0) {
                [self showAlert:@"请先设置流媒体URL"];
                return;
            }
            [self startStreamPlayback];
        } else {
            [self showAlert:@"请先选择视频源类型"];
            return;
        }
        
        g_cameraRunning = YES;
        [self setupFrameTimer];
        NSLog(@"虚拟相机启动成功");
    } @catch (NSException *exception) {
        NSLog(@"启动虚拟相机时发生异常: %@", exception.reason);
        [self showAlert:[NSString stringWithFormat:@"启动失败: %@", exception.reason]];
    }
}

- (void)startLocalVideoPlayback {
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:self.localVideoURL];
    [self setupPlayerWithItem:playerItem];
}

- (void)startStreamPlayback {
    NSURL *streamURL = [NSURL URLWithString:self.streamURL];
    if (!streamURL) {
        [self showAlert:@"无效的流媒体URL"];
        return;
    }
    
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:streamURL];
    [self setupPlayerWithItem:playerItem];
}

- (void)setupPlayerWithItem:(AVPlayerItem *)playerItem {
    // 清理之前的资源
    [self cleanupPlayer];
    
    g_videoOutput = [[AVPlayerItemVideoOutput alloc] init];
    [playerItem addOutput:g_videoOutput];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePlaybackError:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:playerItem];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:playerItem];
    
    g_player = [AVPlayer playerWithPlayerItem:playerItem];
    [self setupPreviewLayer];
    [g_player play];
}

- (void)cleanupPlayer {
    if (g_player) {
        [g_player pause];
        g_player = nil;
    }
    g_videoOutput = nil;
}

- (void)setupPreviewLayer {
    if (self.previewLayer) {
        [self.previewLayer removeFromSuperlayer];
    }
    
    self.previewLayer = [[AVSampleBufferDisplayLayer alloc] init];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.previewLayer.frame = self.view.bounds;
    [self.view.layer addSublayer:self.previewLayer];
}

- (void)setupFrameTimer {
    if (g_frameTimer) {
        dispatch_source_cancel(g_frameTimer);
        g_frameTimer = nil;
    }
    
    g_frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_frameTimer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 30, 0);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(g_frameTimer, ^{
        [weakSelf captureCurrentFrame];
    });
    
    dispatch_resume(g_frameTimer);
}

- (void)captureCurrentFrame {
    if (!g_videoOutput || !g_player) return;
    
    CMTime currentTime = g_player.currentTime;
    if ([g_videoOutput hasNewPixelBufferForItemTime:currentTime]) {
        CVPixelBufferRef pixelBuffer = [g_videoOutput copyPixelBufferForItemTime:currentTime itemTimeForDisplay:nil];
        if (pixelBuffer) {
            if (g_currentPixelBuffer) {
                CVPixelBufferRelease(g_currentPixelBuffer);
            }
            g_currentPixelBuffer = pixelBuffer;
            [self updatePreviewLayer:pixelBuffer];
        }
    }
}

- (void)updatePreviewLayer:(CVPixelBufferRef)pixelBuffer {
    if (!self.previewLayer || !pixelBuffer) return;
    
    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPixelBuffer:pixelBuffer];
    if (sampleBuffer) {
        [self.previewLayer enqueueSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
    }
}

- (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    CMSampleBufferRef sampleBuffer = NULL;
    CMVideoFormatDescriptionRef formatDescription = NULL;
    
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    if (status != noErr) {
        return NULL;
    }
    
    CMSampleTimingInfo timingInfo = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake(0, 30),
        .decodeTimeStamp = kCMTimeInvalid
    };
    
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                      pixelBuffer,
                                                      formatDescription,
                                                      &timingInfo,
                                                      &sampleBuffer);
    
    CFRelease(formatDescription);
    
    return (status == noErr) ? sampleBuffer : NULL;
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    [g_player seekToTime:kCMTimeZero];
    [g_player play];
}

- (void)handlePlaybackError:(NSNotification *)notification {
    NSError *error = [notification.userInfo objectForKey:AVPlayerItemFailedToPlayToEndTimeErrorKey];
    NSLog(@"播放视频时发生错误: %@", error.localizedDescription);
    [self showAlert:[NSString stringWithFormat:@"播放失败: %@", error.localizedDescription]];
}

- (void)stopVirtualCamera {
    if (!g_cameraRunning) {
        NSLog(@"虚拟相机未运行");
        return;
    }
    
    [self cleanupResources];
    NSLog(@"虚拟相机已停止");
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" 
                                                                   message:message 
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 相册选择和EXIF提取
- (void)openPhotoLibraryForVideoSource {
    if ([PHPhotoLibrary authorizationStatus] != PHAuthorizationStatusAuthorized) {
        [self showAlert:@"需要相册访问权限"];
        return;
    }
    
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[(NSString *)kUTTypeMovie];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)openPhotoLibraryForExif {
    if ([PHPhotoLibrary authorizationStatus] != PHAuthorizationStatusAuthorized) {
        [self showAlert:@"需要相册访问权限"];
        return;
    }
    
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[(NSString *)kUTTypeImage, (NSString *)kUTTypeMovie];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info {
    NSURL *mediaURL = info[UIImagePickerControllerMediaURL];
    if ([self.selectedVideoSource isEqualToString:@"local"]) {
        self.localVideoURL = mediaURL;
        NSLog(@"设置本地视频源: %@", mediaURL);
    } else {
        NSLog(@"处理EXIF文件: %@", mediaURL);
        [self extractExifFromMedia:mediaURL];
    }

    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)extractExifFromMedia:(NSURL *)mediaURL {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)mediaURL, NULL);
    if (source) {
        NSDictionary *metadata = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
        
        if (metadata) {
            NSDictionary *exifData = metadata[(NSString *)kCGImagePropertyExifDictionary];
            NSString *cameraMake = exifData[(NSString *)kCGImagePropertyExifMake];
            NSString *cameraModel = exifData[(NSString *)kCGImagePropertyExifModel];
            NSString *originalDateTime = exifData[(NSString *)kCGImagePropertyExifDateTimeOriginal];
            
            [self setCustomExifWithMake:cameraMake model:cameraModel dateTime:originalDateTime];
        }
        
        CFRelease(source);
    }
}

- (void)setCustomExifWithMake:(NSString *)make model:(NSString *)model dateTime:(NSString *)dateTime {
    self.customExifData = @{
        @"Make": make ?: @"",
        @"Model": model ?: @"",
        @"DateTime": dateTime ?: @""
    };
    NSLog(@"设置EXIF: Make: %@, Model: %@, DateTime: %@", make, model, dateTime);
}

@end

#pragma mark - 系统相机钩子
%hook AVCaptureSession

- (void)startRunning {
    NSLog(@"检测到相机启动，准备使用虚拟相机");
    
    if (g_virtualCameraVC && g_cameraRunning) {
        NSLog(@"虚拟相机已在运行，继续使用虚拟内容");
        return; // 不调用原始方法，完全使用虚拟相机
    }
    
    %orig; // 如果虚拟相机未运行，使用系统相机
}

- (void)stopRunning {
    NSLog(@"系统相机停止");
    %orig;
}

%end

%ctor {
    NSLog(@"VirtualCamera tweak 已加载");
}