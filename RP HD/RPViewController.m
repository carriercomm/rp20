//
//  RPViewController.m
//  RP HD
//
//  Created by Giacomo Tufano on 15/03/12.
//  ©2013 Giacomo Tufano.
//  Licensed under MIT license. See LICENSE file or http://www.opensource.org/licenses/mit-license.php
//

#import "RPViewController.h"
#import "RPAppDelegate.h"
#import <MediaPlayer/MediaPlayer.h>
#import "STKeychain/STKeychain.h"
#import "SongAdder.h"
#import "Song.h"
#import "RPViewController+UI.h"
#import "Reachability.h"
#import "PiwikTracker.h"
#import "RaptureXML/RXMLElement.h"

void audioRouteChangeListenerCallback(void *inUserData, AudioSessionPropertyID inPropertyID, UInt32 inPropertyValueSize, const void *inPropertyValue);

@interface RPViewController () <UIPopoverControllerDelegate, RPLoginControllerDelegate, AVAudioSessionDelegate, UIActionSheetDelegate>

@property (strong, nonatomic) Reachability *internetReachability;
@property (strong, nonatomic) NSTimer *networkTimer;
@property NSUInteger bufferSizeInSeconds;

@property BOOL isStatusBarHidden;

@end

@implementation RPViewController

#pragma mark -
#pragma mark HD images loading

-(void)scheduleImagesTimer
{
    if(self.theImagesTimer)
    {
        NSLog(@"*** WARNING: scheduleImagesTimer called with a valid timer (%@) already active!", self.theImagesTimer);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval howMuchTimeBetweenImages = 60.0;
        switch (self.bitrateSelector.selectedSegmentIndex) {
            case 0:
                howMuchTimeBetweenImages = 60.0;
                break;
            case 1:
                howMuchTimeBetweenImages = 20.0;
                break;
            case 2:
                howMuchTimeBetweenImages = 15.0;
                break;
            default:
                break;
        }
        self.theImagesTimer = [NSTimer scheduledTimerWithTimeInterval:howMuchTimeBetweenImages target:self selector:@selector(loadNewImage:) userInfo:nil repeats:YES];
        // While we are at it, let's load a first image...
        [self loadNewImage:nil];
        DLog(@"Scheduling images timer (%@) setup to %f.0 seconds", self.theImagesTimer, howMuchTimeBetweenImages);
    });
}

-(void)unscheduleImagesTimer
{
    DLog(@"Unscheduling images timer (%@)", self.theImagesTimer);
    if(self.theImagesTimer == nil)
    {
        NSLog(@"*** WARNING: unscheduleImagesTimer called with no valid timer around!");
        return;
    }
    [self.theImagesTimer invalidate];
    self.theImagesTimer = nil;
}

-(void)loadNewImage:(NSTimer *)timer
{
    NSMutableURLRequest *req;
    if(self.isPSDPlaying)
    {
        DLog(@"Requesting PSD image");
        req = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:kHDImagePSDURL]];
        [req addValue:self.cookieString forHTTPHeaderField:@"Cookie"];
    }
    else
    {
        req = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:kHDImageURLURL]];
    }
    [req setCachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData];
    [req addValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [NSURLConnection sendAsynchronousRequest:req queue:self.imageLoadQueue completionHandler:^(NSURLResponse *res, NSData *data, NSError *err)
     {
         if(data)
         {
             NSString *imageUrl = [[[NSString alloc]  initWithBytes:[data bytes] length:[data length] encoding: NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
             if(imageUrl)
             {
                 NSURLRequest *req = [[NSURLRequest alloc] initWithURL:[NSURL URLWithString:imageUrl]];
                 [NSURLConnection sendAsynchronousRequest:req queue:self.imageLoadQueue completionHandler:^(NSURLResponse *res, NSData *data, NSError *err)
                  {
                      if(data)
                      {
                          UIImage *temp = [UIImage imageWithData:data];
                          DLog(@"Loaded %@, sending it to screen", [res URL]);
                          // Protect from 404's
                          if(temp)
                          {
                              // load images on the main thread (cross-dissolve them)
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  self.dissolveHdImage.image = temp;
                                  [UIView transitionFromView:self.hdImage toView:self.dissolveHdImage duration:1.5 options:UIViewAnimationOptionShowHideTransitionViews | UIViewAnimationOptionTransitionCrossDissolve completion:^(BOOL finished){
                                      self.hdImage.image = temp;
                                      self.hdImage.hidden = NO;
                                      self.dissolveHdImage.hidden = YES;
                                  }];
                                  // If we have a second screen, update also there (faster animations)
                                  if ([[UIScreen screens] count] > 1)
                                      [((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).TVviewController.TVImage setImage:temp];
                              });
                          }
                      }
                      else
                      {
                          DLog(@"Failed loading image from: <%@>", [res URL]);
                      }
                  }];
             }
             else {
                 DLog(@"Got an invalid URL");
             }
         }
     }];
}

#pragma mark -
#pragma mark Metadata management

- (void)nowPlaySetupWithArtist:(NSString *)artist andTitle:(NSString *)title andAlbum:(NSString *)album andArtwork:(UIImage *)image {
    NSDictionary *mpInfo;
    UIImage *albumImage;
    if (!image) {
        albumImage = [UIImage imageNamed:@"RP-meta"];
    } else {
        albumImage = image;
    }
    MPMediaItemArtwork *albumArt = [[MPMediaItemArtwork alloc] initWithImage:albumImage];
    if (albumArt) {
        mpInfo = @{MPMediaItemPropertyArtist: artist,
                   MPMediaItemPropertyTitle: title,
                   MPMediaItemPropertyAlbumTitle: album,
                   MPMediaItemPropertyArtwork: albumArt};
    } else {
        mpInfo = @{MPMediaItemPropertyArtist: artist,
                   MPMediaItemPropertyTitle: title,
                   MPMediaItemPropertyAlbumTitle: album};
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:mpInfo];
    });
    DLog(@"set MPNowPlayingInfoCenter to \"%@ - %@\"", mpInfo[MPMediaItemPropertyArtist], mpInfo[MPMediaItemPropertyTitle]);
}

- (void)metadataHandler:(NSString *)title {
    // This function get metadata directly in case of PSD (no stream metadata)
    NSString *urlString;
    if (title) {
        DLog(@"This is newMetadataHandler: called for %@", title);
        // Get song metadata
        NSString *encodedTitle = (NSString *)CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)title, NULL, (CFStringRef)@"!*'();:@&=+$,/?%#[]", kCFStringEncodingUTF8));
        urlString = [NSString stringWithFormat:kRPMetadataEndpoint, encodedTitle];
    } else {
        DLog(@"This is newMetadataHandler: called for PSD song");
        urlString = kRPPSDMetadataEndpoint;
    }
    DLog(@"URL: %@", urlString);
    NSMutableURLRequest *req = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:urlString]];
    // Shutdown cache (don't) and cookie management (we'll send them manually, if needed)
    [req setCachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData];
    [req addValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [req setHTTPShouldHandleCookies:NO];
    if (!title) {
        // Add cookies to manage PSD play
        [req addValue:self.cookieString forHTTPHeaderField:@"Cookie"];
    }
    [NSURLConnection sendAsynchronousRequest:req queue:self.imageLoadQueue completionHandler:^(NSURLResponse *res, NSData *data, NSError *err)
     {
         DLog(@"metadata received %@ ", (data) ? @"successfully." : @"with errors.");
         if(data)
         {
             RXMLElement *rootXML = [RXMLElement elementFromXMLData:data];
             NSString __block *artist = [rootXML child:@"artist"].text;
             NSString __block *title = [rootXML child:@"title"].text;
             NSString __block *album = [rootXML child:@"album"].text;
             // remembering songid for forum view
             self.currentSongId = [rootXML child:@"songid"].text;
             DLog(@"Song id is %@.", self.currentSongId);
             [self nowPlaySetupWithArtist:artist andTitle:title andAlbum:album andArtwork:nil];
             dispatch_async(dispatch_get_main_queue(), ^{
                 self.metadataInfo.text = self.rawMetadataString = title;
                 // If we have a second screen, update also there
                 if ([[UIScreen screens] count] > 1) {
                     ((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).TVviewController.songNameOnTV.text = title;
                 }
                 [self.rpWebButton setBackgroundImage:[UIImage imageNamed:@"RP-meta"] forState:UIControlStateNormal];
                 [self.rpWebButton setBackgroundImage:[UIImage imageNamed:@"RP-meta"] forState:UIControlStateHighlighted];
                 [self.rpWebButton setBackgroundImage:[UIImage imageNamed:@"RP-meta"] forState:UIControlStateSelected];
                 self.coverImage = nil;
                 if(!self.viewIsLandscape) {
                     self.metadataInfo.text = [NSString stringWithFormat:@"%@\n%@", artist, title];
                 }
                 // In any case, reset the "add song" capability (we have a new song, it seems).
                 self.songIsAlreadySaved = NO;
                 [self.songListButton setImage:[UIImage imageNamed:@"pbutton-addsong"] forState:UIControlStateNormal];
                 [self.songListButton setImage:[UIImage imageNamed:@"pbutton-addsong"] forState:UIControlStateHighlighted];
                 [self.songListButton setImage:[UIImage imageNamed:@"pbutton-addsong"] forState:UIControlStateSelected];
             });
             // Now get song text (iPad only)
             NSString *lyrics = [rootXML child:@"lyrics"].text;
             if (!lyrics) {
                 DLog(@"No lyrics for the song");
                 lyrics = @"\r\r\r\r\rNo Lyrics Found.";
             } else {
                 DLog(@"Lyrics for the song found.");
                 lyrics = [lyrics stringByReplacingOccurrencesOfString:@"<br />" withString:@"\n"];
             }
             dispatch_async(dispatch_get_main_queue(), ^{
                 self.lyricsText.text = lyrics;
                 [self.lyricsText scrollRangeToVisible:NSMakeRange(0, 0)];
             });
             // Now get album artwork
             NSString *temp = [rootXML child:@"large_cover"].text;
             DLog(@"URL for Artwork: <%@>", temp);
             [self.imageLoadQueue cancelAllOperations];
             NSURLRequest *req = [[NSURLRequest alloc] initWithURL:[NSURL URLWithString:temp]];
             [NSURLConnection sendAsynchronousRequest:req queue:self.imageLoadQueue completionHandler:^(NSURLResponse *res, NSData *data, NSError *err)
              {
                  if(data)
                  {
                      self.coverImage = [UIImage imageWithData:data];
                      // Update metadata info
                      if(self.coverImage != nil)
                      {
                          dispatch_async(dispatch_get_main_queue(), ^{
                              // Set image
                              self.coverImageView.image = self.coverImage;
                              [self nowPlaySetupWithArtist:artist andTitle:title andAlbum:album andArtwork:self.coverImage];
                              [self.rpWebButton setBackgroundImage:self.coverImage forState:UIControlStateNormal];
                              [self.rpWebButton setBackgroundImage:self.coverImage forState:UIControlStateHighlighted];
                              [self.rpWebButton setBackgroundImage:self.coverImage forState:UIControlStateSelected];
                          });
                      }
                  }
              }];
         }
     }];
}

-(void)tvExternalScreenInited:(NSNotification *)note
{
    // copy metadata and current HD image
    if ([[UIScreen screens] count] > 1)
    {
        ((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).TVviewController.songNameOnTV.text = self.metadataInfo.text;
        [((RPAppDelegate *)[[UIApplication sharedApplication] delegate]).TVviewController.TVImage setImage:self.hdImage.image];
    }

}

#pragma mark -
#pragma mark Actions

- (void)playMainStream
{
    [self interfacePlayPending];
    [[PiwikTracker sharedInstance] sendEventWithCategory:@"action" action:@"play" label:@""];
    [self activateNotifications];
    [self.theStreamer setStreamUrl:self.theRedirector isFile:NO];
    [self.theStreamer startStream];
}

-(void)setupFading:(AVPlayer *)stream fadeOut:(BOOL)isFadingOut startingAt:(CMTime)start ending:(CMTime)end
{
    DLog(@"This is setupFading fading %@ stream %@ from %lld to %lld", isFadingOut ? @"out" : @"in", stream, start.value/start.timescale, end.value/end.timescale);
    // AVPlayerObject is a property which points to an AVPlayer
    AVPlayerItem *myAVPlayerItem = stream.currentItem;
    AVAsset *myAVAsset = myAVPlayerItem.asset;
    NSArray *audioTracks = [myAVAsset tracksWithMediaType:AVMediaTypeAudio];
    
    NSMutableArray *allAudioParams = [NSMutableArray array];
    for (AVAssetTrack *track in audioTracks)
    {
        AVMutableAudioMixInputParameters *audioInputParams = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
        if(isFadingOut)
            [audioInputParams setVolumeRampFromStartVolume:1.0 toEndVolume:0 timeRange:CMTimeRangeFromTimeToTime(start, end)];
        else
            [audioInputParams setVolumeRampFromStartVolume:0 toEndVolume:1.0 timeRange:CMTimeRangeFromTimeToTime(start, end)];
        DLog(@"Adding %@ to allAudioParams", audioInputParams);
        [allAudioParams addObject:audioInputParams];
    }
    AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
    [audioMix setInputParameters:allAudioParams];
    [myAVPlayerItem setAudioMix:audioMix];
}

-(void)presetFadeOutToCurrentTrack:(AVPlayer *)streamToBeFaded startingAt:(int)start forSeconds:(int)duration
{
    DLog(@"This is presetFadeOutToCurrentTrack called for %@, starting at %d and for %d seconds.", streamToBeFaded, start, duration);
    [self setupFading:streamToBeFaded fadeOut:YES startingAt:CMTimeMake(start, 1) ending:CMTimeMake(start + duration, 1)];
}

-(void)fadeOutCurrentTrackNow:(AVPlayer *)streamToBeFaded forSeconds:(int)duration
{
    int32_t preferredTimeScale = 600;
    CMTime durationTime = CMTimeMakeWithSeconds((Float64)duration, preferredTimeScale);
    CMTime startTime = streamToBeFaded.currentItem.currentTime;
    CMTime endTime = CMTimeAdd(startTime, durationTime);
    DLog(@"This is fadeOutCurrentTrackNow called for %@ and %d seconds (current time is %lld).", streamToBeFaded, duration, startTime.value/startTime.timescale);
    [self setupFading:streamToBeFaded fadeOut:YES startingAt:startTime ending:endTime];
}

-(void)fadeInCurrentTrackNow:(AVPlayer *)streamToBeFaded forSeconds:(int)duration
{
    int32_t preferredTimeScale = 600;
    CMTime durationTime = CMTimeMakeWithSeconds((Float64)duration, preferredTimeScale);
    CMTime startTime = streamToBeFaded.currentItem.currentTime;
    CMTime endTime = CMTimeAdd(startTime, durationTime);
    DLog(@"This is fadeInCurrentTrackNow called for %@ and %d seconds (current time is %lld).", streamToBeFaded, duration, startTime.value/startTime.timescale);
    [self setupFading:streamToBeFaded fadeOut:NO startingAt:startTime ending:endTime];
}

-(void)stopPsdFromTimer:(NSTimer *)aTimer
{
    DLog(@"This is the PSD timer triggering the end of the PSD song");
    // If still playing PSD, restart "normal" stream
    if(self.isPSDPlaying)
    {
        [self interfacePlayPending];
        self.isPSDPlaying = NO;
        if(self.thePsdTimer)
        {
            [self.thePsdTimer invalidate];
            self.thePsdTimer = nil;
        }
        DLog(@"Stopping stream in timer firing (starting fade out)");
        if(self.theImagesTimer)
            [self unscheduleImagesTimer];
        // restart main stream...
        [self playMainStream];
    }
}

// Here PSD streaming is ready to start (and it is started)
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    DLog(@"*** observeValueForKeyPath:ofObject:change:context called!");
    if (object == self.thePsdStreamer && [keyPath isEqualToString:@"status"])
    {
        if (self.thePsdStreamer.status == AVPlayerStatusReadyToPlay)
        {
            DLog(@"psdStreamer is ReadyToPlay for %@ secs", self.psdDurationInSeconds);
            // reduce psdDurationInSeconds to allow for some fading
            NSNumber *startPsdFadingTime = @([self.psdDurationInSeconds doubleValue] - kPsdFadeOutTime);
            // Prepare stop and restart stream after the claimed lenght (minus kPsdFadeOutTime seconds to allow for fading)...
            if(self.thePsdTimer)
            {
                [self.thePsdTimer invalidate];
                self.thePsdTimer = nil;
            }
            DLog(@"We'll start PSD fading and prepare to stop after %@ secs", startPsdFadingTime);
            self.thePsdTimer = [NSTimer scheduledTimerWithTimeInterval:[startPsdFadingTime doubleValue] target:self selector:@selector(stopPsdFromTimer:) userInfo:nil repeats:NO];
            // start slow
            [self fadeInCurrentTrackNow:self.thePsdStreamer forSeconds:kFadeInTime];
            [self.thePsdStreamer play];
            DLog(@"Setting fade out after %@ sec for %.0f sec", startPsdFadingTime, kPsdFadeOutTime);
            [self presetFadeOutToCurrentTrack:self.thePsdStreamer startingAt:[startPsdFadingTime intValue] forSeconds:kPsdFadeOutTime];
            // Stop main streamer, remove observers and and reset timers it.
            if(self.theImagesTimer)
                [self unscheduleImagesTimer];
            if(self.isPSDPlaying)
            {
                // Fade out and quit previous stream
                [self fadeOutCurrentTrackNow:self.theOldPsdStreamer forSeconds:kPsdFadeOutTime];
                dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, kPsdFadeOutTime * NSEC_PER_SEC);
                dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                    DLog(@"Previous PSD stream now stopped!");
                    [self.theOldPsdStreamer pause];
                    self.theOldPsdStreamer = nil;
                });
            }
            else
            {
                // Quit main stream after fade-in of PSD
                self.isPSDPlaying = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kFadeInTime * NSEC_PER_SEC), dispatch_get_main_queue(), ^(void){
                    DLog(@"Main stream now stopped!");
                    [self.theStreamer stopStream];
                });
            }
            [self interfacePsd];
        }
        else if (self.thePsdStreamer.status == AVPlayerStatusFailed)
        {
            // something went wrong. player.error should contain some information
            DLog(@"Error starting PSD streamer: %@", self.thePsdStreamer.error);
            self.thePsdStreamer = nil;
            [self playMainStream];
        }
        else if (self.thePsdStreamer.status == AVPlayerStatusUnknown)
        {
            // something went wrong. player.error should contain some information
            DLog(@"AVPlayerStatusUnknown");
        }
        else
        {
            DLog(@"Unknown status received: %d", self.thePsdStreamer.status);
        }
    }
    else
    {
        DLog(@"Something else called observeValueForKeyPath. KeyPath is %@", keyPath);
    }
}

- (void)mainStreamerError:(NSString *)streamError {
    // something went wrong. player.error should contain some information
    DLog(@"Error starting the main streamer: %d", [self.theStreamer getStreamStatus]);
    [self playMainStream];
}

- (void)SRKPlayStarted {
    DLog(@"Stream is connected.");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self interfacePlay];
        // If PSD is still streaming (that means we're returning from PSD) fade out PSD.
        if(self.thePsdStreamer.rate == 1.0) {
            [self fadeOutCurrentTrackNow:self.thePsdStreamer forSeconds:kPsdFadeOutTime];
            // ...while giving the delay to the fading
            [self.thePsdStreamer removeObserver:self forKeyPath:@"status"];
            dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, kPsdFadeOutTime * NSEC_PER_SEC);
            dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                DLog(@"PSD stream now stopped!");
                [self.thePsdStreamer pause];
                self.thePsdStreamer = nil;
            });
        }
    });
}

- (void) SRKURLNotFound {
    [self mainStreamerError:@"Unknown error when attempting to connect to the server."];
}

- (void) SRKHttpError: (CFIndex)errorCode {
    [self mainStreamerError:[NSString stringWithFormat:@"HTTP error: %ld", errorCode]];
}

- (void) SRKConnecting {
    DLog(@"Stream connecting");
    self.metadataInfo.text = @"Connecting...";
}

- (void) SRKIsBuffering {
    DLog(@"Stream Buffering");
    dispatch_async(dispatch_get_main_queue(), ^{
        self.metadataInfo.text = @"Buffering...";
        [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(bufferingTextManager:) userInfo:nil repeats:YES];
    });
}

- (void) SRKRealtimeMetaChanged: (NSString *)title withUrl: (NSString *) url {
    NSLog(@"Metadata changed: '%@'", title);
    [self metadataHandler:title];
}

- (void)bufferingTextManager:(NSTimer *)theTimer {
    if ([self.theStreamer getStreamStatus] == SRK_STATUS_BUFFERING) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.metadataInfo.text = [NSString stringWithFormat:@"Buffering (%.0f%%)", [self.theStreamer currBufferUsageInSeconds] * 100.0 / self.bufferSizeInSeconds];
        });
    } else {
        [theTimer invalidate];
    }
}

- (void)playPSDNow
{
    DLog(@"playPSDNow called. Cookie is <%@>", self.cookieString);
    [self interfacePsdPending];
    NSString *psdURLString = [NSString stringWithFormat:@"http://www.radioparadise.com/ajax_replace-x.php?option=0&agent=iOS&bitrate=%d", self.bitrateSelector.selectedSegmentIndex];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:psdURLString]];
    [req addValue:self.cookieString forHTTPHeaderField:@"Cookie"];
    [NSURLConnection sendAsynchronousRequest:req queue:self.imageLoadQueue completionHandler:^(NSURLResponse *res, NSData *data, NSError *err)
     {
         if(data)
         {
             NSString *retValue = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
             retValue = [retValue stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
             if (!retValue || [retValue length] == 0) {
                 // This is an invalid login
                 [STKeychain deleteItemForUsername:@"cookies" andServiceName:@"RP" error:&err];
                 self.cookieString = nil;
                 [self startPSD:self];
                 return;
             }
             NSArray *values = [retValue componentsSeparatedByString:@"|"];
             if([values count] != 5)
             {
                 NSLog(@"ERROR: wrong number of values (%d) returned from ajax_replace", [values count]);
                 NSLog(@"retValue: <%@>", retValue);
                 // This could be from the password changed on the RP web site in itself. Reset the cache so that the next PSD request will trigger a new login and get back to the current stream.
                 self.cookieString = nil;
                 [STKeychain deleteItemForUsername:@"cookies" andServiceName:@"RP" error:&err];
                 NSString *userName = [[NSUserDefaults standardUserDefaults] stringForKey:@"userName"];
                 [STKeychain deleteItemForUsername:userName andServiceName:@"RP" error:&err];
                 [self startPSD:self];
                 return;
             }
             NSString *psdSongUrl = [values objectAtIndex:0];
             NSNumber *psdSongLenght = [values objectAtIndex:1];
             NSNumber * __unused psdSongFadeIn = [values objectAtIndex:2];
             NSNumber * __unused psdSongFadeOut = [values objectAtIndex:3];
             NSNumber * __unused psdWhatever = [values objectAtIndex:4];
             DLog(@"Got PSD song information: <%@>, should run for %@ ms, with fade-in, fade-out for %@ and %@", psdSongUrl, psdSongLenght, psdSongFadeIn, psdSongFadeOut);
             // reset stream on main thread
             dispatch_async(dispatch_get_main_queue(), ^{
                 // If PSD is already running...
                 if(self.isPSDPlaying)
                 {
                     self.theOldPsdStreamer = self.thePsdStreamer;
                     [self.thePsdStreamer removeObserver:self forKeyPath:@"status"];
                 }
                 // Begin buffering...
                 self.thePsdStreamer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:psdSongUrl]];
                 self.thePsdStreamer.allowsExternalPlayback = NO;
                 [[PiwikTracker sharedInstance] sendEventWithCategory:@"action" action:@"playPSD" label:@""];
                 // Add observer for real start and stop.
                 self.psdDurationInSeconds = @(([psdSongLenght doubleValue] / 1000.0));
                 [self.thePsdStreamer addObserver:self forKeyPath:@"status" options:0 context:nil];
             });
         }
         else // we have an error in PSD processing, (re)start main stream)
         {
             [self playMainStream];
         }
     }];
}

- (void)stopPressed:(id)sender
{
    if(self.isPSDPlaying)
    {
        // If PSD is running, simply get back to the main stream by firing the end timer...
        DLog(@"Manually firing the PSD timer (starting fading now)");
        [[PiwikTracker sharedInstance] sendEventWithCategory:@"action" action:@"stopPSD" label:@""];
        [self.thePsdTimer fire];
    }
    else
    {
        [self interfaceStopPending];
        // Process stop request.
        [[PiwikTracker sharedInstance] sendEventWithCategory:@"action" action:@"stop" label:@""];
        [self.theStreamer stopStream];
        // Let's give the stream a couple seconds to really stop itself
        double delayInSeconds = 1.0;    //was 2.0: MONITOR!
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delayInSeconds * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self removeNotifications];
            if(self.theImagesTimer)
                [self unscheduleImagesTimer];
            [self interfaceStop];
            // if called from bitrateChanged, restart
            if(sender == self)
                [self playMainStream];
        });
    }
}

- (IBAction)playOrStop:(id)sender
{
    if([self.theStreamer getStreamStatus] != SRK_STATUS_STOPPED || self.isPSDPlaying)
        [self stopPressed:nil];
    else
        [self playMainStream];
}

- (IBAction)bitrateChanged:(id)sender 
{
    // Set custom images
    NSArray *imageNames = @[@"24k", @"64k", @"128k"];
    for (int i = 0; i < 3; i++) {
        UIImage *theImage;
        if([[UIDevice currentDevice] systemVersion].integerValue >= 7) {
            theImage = [[UIImage imageNamed:imageNames[i]] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        } else {
            theImage = [UIImage imageNamed:imageNames[i]];
        }
        [sender setImage:theImage forSegmentAtIndex:i];
    }
    NSString *imageToBeSet;
    switch (((UISegmentedControl *)sender).selectedSegmentIndex)
    {
        case 0:
            self.theRedirector = kRPURL24K;
            imageToBeSet = @"24ks";
            [[PiwikTracker sharedInstance] sendEventWithCategory:@"bitrateChanged" action:@"24Kselected" label:@""];
            break;
        case 1:
            self.theRedirector = kRPURL64K;
            imageToBeSet = @"64ks";
            [[PiwikTracker sharedInstance] sendEventWithCategory:@"bitrateChanged" action:@"64Kselected" label:@""];
            break;
        case 2:
            self.theRedirector = kRPURL128K;
            imageToBeSet = @"128ks";
            [[PiwikTracker sharedInstance] sendEventWithCategory:@"bitrateChanged" action:@"128Kselected" label:@""];
            break;
        default:
            break;
    }
    if([[UIDevice currentDevice] systemVersion].integerValue >= 7) {
        [sender setImage:[[UIImage imageNamed:imageToBeSet] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forSegmentAtIndex:((UISegmentedControl *)sender).selectedSegmentIndex];
    } else {
        [sender setImage:[UIImage imageNamed:imageToBeSet] forSegmentAtIndex:((UISegmentedControl *)sender).selectedSegmentIndex];
    }
    // Save it for next time (+1 to use 0 as "not saved")
    [[NSUserDefaults standardUserDefaults] setInteger:1 + ((UISegmentedControl *)sender).selectedSegmentIndex forKey:@"bitrate"];
    // If needed, stop the stream
    if([self.theStreamer getStreamStatus] != SRK_STATUS_STOPPED)
        [self stopPressed:self];
}

- (IBAction)startPSD:(id)sender
{
    // Try to understand if we have cookie string in KeyChain
    NSError *err;
    self.cookieString = [STKeychain getPasswordForUsername:@"cookies" andServiceName:@"RP" error:&err];
    if(self.cookieString)
    {
        [self playPSDNow];
        return;
    }
    if(self.cookieString != nil)
    {   // already logged in. no need to show the login box
        [self playPSDNow];
    }
    else
    {
        // Init controller and set ourself for callback
        RPLoginController * theLoginBox = [[RPLoginController alloc] initWithNibName:@"RPLoginController" bundle:[NSBundle mainBundle]];
        theLoginBox.delegate = self;
        // if iPad, embed in a popover, go modal for iPhone
        if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        {
            if(self.theLoginBox == nil)
                self.theLoginBox = [[UIPopoverController alloc] initWithContentViewController:theLoginBox];
            self.theLoginBox.popoverContentSize = CGSizeMake(320, 207);
            [self.theLoginBox presentPopoverFromRect:self.psdButton.frame inView:self.view permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
        }
        else
        {
            theLoginBox.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:theLoginBox animated:YES completion:nil];
        }
        // Release...
        theLoginBox = nil;
    }
}

- (IBAction)showStatusBar:(id)sender {
    DLog(@"Now show the status bar");
    self.isStatusBarHidden = NO;
    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationSlide];
}

- (IBAction)hideStatusBar:(id)sender {
    DLog(@"Now Hide the status bar");
    self.isStatusBarHidden = YES;
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationSlide];
}

- (void)RPLoginControllerDidCancel:(RPLoginController *)controller
{
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone)
        [controller dismissViewControllerAnimated:YES completion:nil];
}

- (void)RPLoginControllerDidSelect:(RPLoginController *)controller withCookies:(NSString *)cookiesString
{
    // dismiss the popover (if needed)
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
    {
        if([self.theLoginBox isPopoverVisible])
            [self.theLoginBox dismissPopoverAnimated:YES];
    }
    else // iPhone
        [controller dismissViewControllerAnimated:YES completion:nil];
    self.cookieString = cookiesString;
    [self playPSDNow];
}

- (IBAction)songListAction:(id)sender
{
    if(self.songIsAlreadySaved)
    {
        [self showSongList];
        return;
    }
    UIActionSheet *theChoices = [[UIActionSheet alloc] initWithTitle:@"What do you want do to?" delegate:self cancelButtonTitle:@"Nothing" destructiveButtonTitle:nil otherButtonTitles:@"Tunemark List", @"Mark Song", nil];
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        [theChoices showFromRect:self.songListButton.frame inView:self.view animated:YES];
    else
        [theChoices showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    DLog(@"User choose: %d", buttonIndex);
    if(buttonIndex == 0)
        [self showSongList];
    else if(buttonIndex == 1)
        [self addCurrentSong];
}

- (void)showSongList
{
    SongsViewController *theSongsBox = [[SongsViewController alloc] initWithNibName:@"SongsViewController" bundle:[NSBundle mainBundle]];
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        theSongsBox.modalPresentationStyle = UIModalPresentationPageSheet;
    else
        theSongsBox.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:theSongsBox animated:YES completion:nil];
    theSongsBox = nil;    
}

- (void)addCurrentSong
{
    // Recover song data...
    NSArray *songPieces = [self.rawMetadataString componentsSeparatedByString:@" - "];
    if([songPieces count] == 2)
    {
        // No save for RP metadata filler
        if([[songPieces objectAtIndex:0] isEqualToString:@"Commercial-free"])
            return;
        SongAdder *theAdder = [[SongAdder alloc] initWithTitle:[songPieces objectAtIndex:1] andArtist:[songPieces objectAtIndex:0] andCoversheet:self.coverImage];
        NSError *err;
        if(![theAdder addSong:&err])
        {
            // An error occurred when saving...
            NSString *temp = [NSString stringWithFormat:@"While saving the song got the error %@, %@", err, [err userInfo]];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Error" message:temp delegate:nil cancelButtonTitle:@"Cancel" otherButtonTitles: nil];
            [alert show];
            return;
        }
        self.songIsAlreadySaved = YES;
        [self.songListButton setImage:[UIImage imageNamed:@"pbutton-songlist"] forState:UIControlStateNormal];
        [self.songListButton setImage:[UIImage imageNamed:@"pbutton-songlist"] forState:UIControlStateHighlighted];
        [self.songListButton setImage:[UIImage imageNamed:@"pbutton-songlist"] forState:UIControlStateSelected];
    }
    else
    {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Error" message:@"Malformed song name, cannot save it." delegate:nil cancelButtonTitle:@"Cancel" otherButtonTitles: nil];
        [alert show];        
    }
}

- (IBAction)showLyrics:(id)sender
{
    self.isLyricsToBeShown = (self.isLyricsToBeShown) ? NO : YES;
    if(self.isLyricsToBeShown)
    {
        [[PiwikTracker sharedInstance] sendView:@"showLyrics"];
        self.lyricsText.hidden = NO;
        [self.lyricsButton setImage:[UIImage imageNamed:@"pbutton-lyrics-active"] forState:UIControlStateNormal];
        [self.lyricsButton setImage:[UIImage imageNamed:@"pbutton-lyrics-active"] forState:UIControlStateHighlighted];
        [self.lyricsButton setImage:[UIImage imageNamed:@"pbutton-lyrics-active"] forState:UIControlStateSelected];
    }
    else
    {
        [[PiwikTracker sharedInstance] sendView:@"hideLyrics"];
        self.lyricsText.hidden = YES;
        [self.lyricsButton setImage:[UIImage imageNamed:@"pbutton-lyrics"] forState:UIControlStateNormal];
        [self.lyricsButton setImage:[UIImage imageNamed:@"pbutton-lyrics"] forState:UIControlStateHighlighted];
        [self.lyricsButton setImage:[UIImage imageNamed:@"pbutton-lyrics"] forState:UIControlStateSelected];
    }
}

- (IBAction)supportRP:(id)sender
{
    [[PiwikTracker sharedInstance] sendView:@"supportPage"];
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://www.radioparadise.com/rp2s-content.php?name=Support&file=settings"]];
}

- (IBAction)minimizer:(id)sender
{
    switch (self.interfaceState) {
        case kInterfaceNormal:
            [self interfaceToMinimized];
            break;
        case kInterfaceMinimized:
            [self interfaceToNormal];
            break;
        case kInterfaceZoomed:
            [self interfaceToNormal];
            break;
        default:
            DLog(@"minimizer called with self.interfaceState to %d", self.interfaceState);
            break;
    }
}

- (IBAction)presentAboutBox:(id)sender
{
    RPAboutBox *theAboutBox;
    if(theAboutBox == nil)
    {
        theAboutBox = [[RPAboutBox alloc] initWithNibName:@"AboutBox" bundle:[NSBundle mainBundle]];
        if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
            theAboutBox.modalPresentationStyle = UIModalPresentationFormSheet;
        else
            theAboutBox.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    [self presentViewController:theAboutBox animated:YES completion:nil];
    theAboutBox = nil;
}

- (IBAction)presentRPWeb:(id)sender
{
    [[PiwikTracker sharedInstance] sendView:@"forumView"];
    if(self.theWebView == nil)
    {
        self.theWebView = [[RPForumView alloc] initWithNibName:@"RPForumView" bundle:[NSBundle mainBundle]];
        if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
            self.theWebView.modalPresentationStyle = UIModalPresentationPageSheet;
        else
            self.theWebView.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    self.theWebView.songId = self.currentSongId;
    self.theWebView.currentSongName = self.rawMetadataString;
    [self presentViewController:self.theWebView animated:YES completion:nil];
    self.theWebView = nil;
}

#pragma mark -
#pragma mark Notifications

-(void)activateNotifications
{
    DLog(@"*** activateNotifications");
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tvExternalScreenInited:) name:kTVInited object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationChangedState:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationChangedState:) name:UIApplicationDidEnterBackgroundNotification object:nil];
}

-(void)removeNotifications
{
    DLog(@"*** removeNotifications");
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kTVInited object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
}

#pragma mark -
#pragma mark Rotation management

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
        return YES;
    if(UIInterfaceOrientationIsLandscape(interfaceOrientation))
        return YES;
    if(interfaceOrientation == UIInterfaceOrientationPortrait)
        return YES;
    return NO;
}

-(NSUInteger)supportedInterfaceOrientations
{
    if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone)
        return UIInterfaceOrientationMaskAllButUpsideDown;
    else
        return UIInterfaceOrientationMaskAll;
}

-(void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    DLog(@"This is willRotateToInterfaceOrientation");
    self.viewIsRotating = YES;
}

-(void)viewDidLayoutSubviews
{
    if(self.viewIsRotating)
    {
        DLog(@"This is viewDidLayoutSubviews called for a \"real\" rotation");
        self.viewIsRotating = NO;
        if(UIInterfaceOrientationIsLandscape(self.interfaceOrientation))
        {
            // if no image timer but systems is playing, schedule timers...
            if(self.theImagesTimer == nil && ([self.theStreamer getStreamStatus] != SRK_STATUS_STOPPED  || self.isPSDPlaying))
                [self scheduleImagesTimer];
            self.viewIsLandscape = YES;
            [self interfaceToNormal];
        }
        else
        {
            // If the streamer for images is active, kill it
            if(self.theImagesTimer && (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone && [[UIScreen screens] count] == 1))
                [self unscheduleImagesTimer];
            self.viewIsLandscape = NO;
            [self interfaceToPortrait:0.5];
        }
    }
    else
        DLog(@"This is viewDidLayoutSubviews called for a layout change");
    [super viewDidLayoutSubviews];
}

// We check returning from a modal controller if layout has changed while this controller was hidden.
-(void)viewDidAppear:(BOOL)animated
{
    if(UIInterfaceOrientationIsLandscape(self.interfaceOrientation))
    {
        DLog(@"Main view appearing in landscape.");
        self.viewIsLandscape = YES;
        [self interfaceToNormal];
    }
    else
    {
        DLog(@"Main view appearing in portrait.");
        self.viewIsLandscape = NO;
        [self interfaceToPortrait:0.0];
    }
}

- (BOOL)prefersStatusBarHidden {
    return self.isStatusBarHidden;
}

#pragma mark -
#pragma mark LoadUnload

- (void)viewDidLoad
{
    [super viewDidLoad];
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationFade];
    [[PiwikTracker sharedInstance] sendView:@"mainUI"];
    // reset text
    self.isStatusBarHidden = YES;
    self.metadataInfo.text = self.rawMetadataString = @"";
    // Let's see if we already have a preferred bitrate
    int savedBitrate = [[NSUserDefaults standardUserDefaults] integerForKey:@"bitrate"];
    if(savedBitrate == 0) {
        self.theRedirector = kRPURL64K;
    } else {
        self.bitrateSelector.selectedSegmentIndex = savedBitrate - 1;
        [self bitrateChanged:self.bitrateSelector];
    }
    // RadioKit init
    self.bufferSizeInSeconds = 15;
    self.theStreamer = [[RadioKit alloc] init];
    [self.theStreamer authenticateLibraryWithKey1:RADIO_KIT_KEY1 andKey2:RADIO_KIT_KEY2];
    [self.theStreamer setBufferWaitTime:self.bufferSizeInSeconds];
    self.theStreamer.delegate = self;
    NSLog(@"RadioKit version: %@", [self.theStreamer version]);
    // Prepare for background audio
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    [[AVAudioSession sharedInstance] setDelegate:self];
    // Listen to route change events
    AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, audioRouteChangeListenerCallback, (__bridge void *)(self));
    [[AVAudioSession sharedInstance] setActive: YES error: nil];
    self.imageLoadQueue = [[NSOperationQueue alloc] init];
    self.interfaceState = kInterfaceNormal;
    self.minimizerButton.enabled = NO;
    self.isLyricsToBeShown = NO;
    self.lyricsText.hidden = YES;
    // Set PSD to not logged, not playing
    self.cookieString = nil;
    self.isPSDPlaying = NO;
    // set bounds and corners
    self.hdImage.layer.cornerRadius = 8.0;
    self.dissolveHdImage.layer.cornerRadius = 8.0;
    self.coverImageView.layer.cornerRadius = 6.0;
    self.rpWebButton.layer.cornerRadius = 4.0;
    self.lyricsText.layer.cornerRadius = 6.0;
    self.hdImage.clipsToBounds = self.dissolveHdImage.clipsToBounds = self.coverImageView.clipsToBounds = self.rpWebButton.clipsToBounds = YES;
    [self fixSegmentedControlForiOS7];
    // Hide lyrics text
    self.lyricsText.text = nil;
    self.interfaceIsTinted = YES;
    // Check network reachability
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(reachabilityChanged:) name: kReachabilityChangedNotification object: nil];
    self.internetReachability = [Reachability reachabilityForInternetConnection];
	[self.internetReachability startNotifier];
    // Automagically start, as per bg request
    if([self.internetReachability currentReachabilityStatus] != NotReachable)
        [self playMainStream];
    // We would like to receive starts and stops
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    [self becomeFirstResponder];
}

- (void)viewDidUnload
{
    [self setMetadataInfo:nil];
    [self setSpinner:nil];
    [self setVolumeViewContainer:nil];
    [self.imageLoadQueue cancelAllOperations];
    [self setImageLoadQueue:nil];
    [self setPlayOrStopButton:nil];
    [self setHdImage:nil];
    [self setLyricsButton:nil];
    [self setRpWebButton:nil];
    [self setMinimizerButton:nil];
    [self setLogoImage:nil];
    [self setBitrateSelector:nil];
    [self setSongNameButton:nil];
    [self setSeparatorImage:nil];
    [self setIPhoneLogoImage:nil];
    [self setPsdButton:nil];
    [self setThePsdStreamer:nil];
    [self setTheOldPsdStreamer:nil];
    [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
    [self resignFirstResponder];
    [[AVAudioSession sharedInstance] setDelegate:nil];
    [self setSongInfoButton:nil];
    [self setSongListButton:nil];
    [self setLyricsText:nil];
    [self setDissolveHdImage:nil];
    [self setAboutButton:nil];
    [self setSupportRPButton:nil];
    [super viewDidUnload];
}

#pragma mark -
#pragma mark Multimedia, Remote Control and Network availability management

- (void) reachabilityChanged: (NSNotification* )note
{
    // if streams are stopped, return
    if([self.theStreamer getStreamStatus] == SRK_STATUS_STOPPED && self.thePsdStreamer.rate == 0.0)
        return;
	Reachability* curReach = [note object];
	NSParameterAssert([curReach isKindOfClass: [Reachability class]]);
    NetworkStatus netStatus = [curReach currentReachabilityStatus];
    NSString* statusString= @"";
    switch (netStatus) {
        case NotReachable: {
            statusString = @"Internet Access Not Available";
            break;
        }
        case ReachableViaWWAN: {
            statusString = @"Internet Reachable via WWAN";
            break;
        }
        case ReachableViaWiFi: {
            statusString= @"Internet Reachable via WiFi";
            break;
        }
    }
    DLog(@"Network status changed: %@", statusString);
    if([self.theStreamer getStreamStatus] != SRK_STATUS_STOPPED || self.thePsdStreamer.rate != 0.0) {
        if(self.networkTimer) {
            [self.networkTimer invalidate];
            self.networkTimer = nil;
        }
        DLog(@"starting a timer to check if stream is not timed out...");
        self.networkTimer = [NSTimer scheduledTimerWithTimeInterval:20.0 target:self selector:@selector(checkIfAStreamRestartIsNeeded:) userInfo:nil repeats:NO];
    }
}

-(void)checkIfAStreamRestartIsNeeded:(NSTimer *)timer {
    self.networkTimer = nil;
    // If psdstreamer is out of buffers
    if(self.thePsdStreamer.rate == 1.0 && self.thePsdStreamer.currentItem.isPlaybackBufferEmpty) {
        DLog(@"PSD stream is STOPPED.");
        [self stopPressed:nil];
    }
}


- (void)endInterruptionWithFlags:(NSUInteger)flags
{
    DLog(@"This is the endInterruptionWithFlags: handler");
    // Manage it only on PSD, Radio Kit will take care of it on main stream
    if(flags == AVAudioSessionInterruptionOptionShouldResume)
    {
        DLog(@"AudioSession is ready to be resumed, doing it.");
        if(self.isPSDPlaying)
            [self.thePsdStreamer play];
    }
    else
    {
        if(self.isPSDPlaying)
        {
            DLog(@"Audiosession is lost. Resetting interface and application status.");
            self.isPSDPlaying = NO;
            if(self.thePsdTimer)
            {
                [self.thePsdTimer invalidate];
                self.thePsdTimer = nil;
            }
            [self.thePsdStreamer removeObserver:self forKeyPath:@"status"];
            self.thePsdStreamer = nil;
        }
    }
}

-(void)applicationChangedState:(NSNotification *)note
{
    DLog(@"applicationChangedState: %@", note.name);
    if([note.name isEqualToString:UIApplicationDidEnterBackgroundNotification])
        dispatch_async(dispatch_get_main_queue(), ^{
            // If we don't have a second screen...
            if ([[UIScreen screens] count] == 1 && self.viewIsLandscape && UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone)
            {
                DLog(@"No more images, please");
                [self unscheduleImagesTimer];
            }
            // We would like to receive starts and stops
            [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
            [self becomeFirstResponder];
        });
    if([note.name isEqualToString:UIApplicationWillEnterForegroundNotification])
        dispatch_async(dispatch_get_main_queue(), ^{
            if([self.theStreamer getStreamStatus] != SRK_STATUS_STOPPED  || self.isPSDPlaying)
            {
                // If we don't have a second screen (else the timer was not stopped)
                if ([[UIScreen screens] count] == 1 && (self.viewIsLandscape || UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad || [[UIScreen screens] count] != 1))
                {
                    DLog(@"Images again, please");
                    [self scheduleImagesTimer];
                }
            }
            [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
            [self resignFirstResponder];
        });
}

- (void) remoteControlReceivedWithEvent: (UIEvent *) receivedEvent
{
    DLog(@"Remote control received");
    if (receivedEvent.type == UIEventTypeRemoteControl) {
        switch (receivedEvent.subtype) 
        {
            case UIEventSubtypeRemoteControlTogglePlayPause:
            case UIEventSubtypeRemoteControlPause:
            case UIEventSubtypeRemoteControlPlay:
                [self playOrStop: nil];
                break;
            case UIEventSubtypeRemoteControlPreviousTrack:
                break;
            case UIEventSubtypeRemoteControlNextTrack:
                // Start PSD on "next track" request
                [self startPSD:nil];
                break;
            default:
                break;
        }
    }
}

- (BOOL) canBecomeFirstResponder 
{
    return YES;
}

@end

#pragma mark - Audio Re-routing detection

void audioRouteChangeListenerCallback(void *inUserData, AudioSessionPropertyID inPropertyID, UInt32 inPropertyValueSize, const void *inPropertyValue)
{
    if (inPropertyID != kAudioSessionProperty_AudioRouteChange)
        return;
    RPViewController *controller = (__bridge RPViewController *) inUserData;
    CFDictionaryRef routeChangeDictionary = inPropertyValue;
    CFNumberRef routeChangeReasonRef = CFDictionaryGetValue (routeChangeDictionary,CFSTR (kAudioSession_AudioRouteChangeKey_Reason));
    SInt32 routeChangeReason;
    CFNumberGetValue (routeChangeReasonRef, kCFNumberSInt32Type, &routeChangeReason);
    if (routeChangeReason ==  kAudioSessionRouteChangeReason_OldDeviceUnavailable) {
        // Stop audio, remember that when PSD is streaming this will not properly stop but simply start normal stream (should be on the new device, though)
        DLog(@"We just lost the audio devices. Stopping stream.");
        [controller stopPressed:nil];
    } else if (routeChangeReason == kAudioSessionRouteChangeReason_NewDeviceAvailable) {
        DLog(@"New audio device plugged in");
    }

}
