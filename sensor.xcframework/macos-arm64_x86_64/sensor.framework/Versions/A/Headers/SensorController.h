//
//  SensorController.h
//  test
//
//  Created by 叶常青 on 2024/4/19.
//

#import <Foundation/Foundation.h>
#import <sensor/sensorProfile.h>
NS_ASSUME_NONNULL_BEGIN


@protocol SensorControllerDelegate
- (void)onSensorScanResult:(NSArray<BLEPeripheral*>*) bleDevices;
@end


@interface SensorController : NSObject
@property (atomic, weak) id<SensorControllerDelegate> delegate;
@property (atomic, retain, readonly) NSArray<BLEPeripheral*>* scanResults;
@property (atomic, assign, readonly) bool isEnable;
@property (atomic, assign, readonly) bool isScaning;
+ (instancetype)getInstance;


-(BLEPeripheral*)getDevice:(NSString*)deviceMac;
-(SensorProfile*)getSensor:(NSString*)deviceMac;
-(NSArray<SensorProfile*>*)getSensors;
-(BOOL)startScan:(NSTimeInterval)scanInterval;
-(void)stopScan;


@end

NS_ASSUME_NONNULL_END
