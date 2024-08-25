# Synchroni SDK + swift demo

## Brief
Synchroni SDK is the software development kit for developers to access OYMotion Synchroni products.
## 1. Permission 

Application will obtain bluetooth permission by itself. 

## 2. Import SDK

```obj-c
#import <sensor/sensor.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
{

}
@property (atomic, retain) SynchronyProfile* profile;
@end
```

## 3. Initalize

```obj-c
//AppDelegate.m
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.profile = [[SynchronyProfile alloc] init];
    return YES;
}


//Implement SynchronyDelegate to get status change and data notification
@protocol SynchronyDelegate

//called when error occurs
- (void)onSynchronyErrorCallback: (NSError*)err;

//please do logic when device disconnected unexpected
- (void)onSynchronyStateChange: (BLEState)newState;

//called when scan finished
- (void)onSynchronyScanResult:(NSArray*) bleDevices;

//called after start data transfer
- (void)onSynchronyNotifyData:(NSData*) rawData;

@end

//ViewController.m
@interface ViewController ()<SynchronyDelegate>

@end

- (void)viewDidLoad {
    [super viewDidLoad];

    AppDelegate* delegate = (AppDelegate*)[UIApplication sharedApplication].delegate;
    self.profile = delegate.profile;
    self.profile.delegate = self;//set delegate
}


```

## 4. Start scan

```obj-c
-(BOOL)startScan;
```

`- (void)onSynchronyScanResult:(NSArray*) bleDevices` 
returns array of BLEPeripheral

```obj-c
    for (BLEPeripheral* bleDevice in bleDevices) {
        NSLog(@"Found device: %@, mac: %@, rssi: %@", bleDevice.peripheralName, bleDevice.macAddress, bleDevice.rssi);
    }
```

## 5. Stop scan

```obj-c
-(void)stopScan;
```


## 6. Connect device


```obj-c
-(BOOL)connect:(BLEPeripheral*)peripheral;
```

## 7. Disconnect

```obj-c
-(void)disconnect;
```


## 8. Get device status

```obj-c
@property (atomic, assign, readonly) BLEState state;
```

Please send command in 'BLEStateConnected' or 'BLEStateRunning'

```obj-c
typedef NS_ENUM(NSInteger, BLEState)
{
    BLEStateInvalid,
    BLEStateIdle,
    BLEStateScaning,
    BLEStateUnDiscovered,
    BLEStateDiscovered,
    BLEStateConnecting,
    BLEStateUnConnected,
    BLEStateConnected,
    BLEStateRunning,
};
```

## 9. DataNotify

### 9.1 get data feature map of DataNotify(optional)

```obj-c
-(GF_RET_CODE)getFeatureMap:(getFeatureMapCallback)cb timeout:(NSTimeInterval)timeout;
```

```c
#define GFD_FEAT_NONE  0x000000000 //None Optional Feature supported
#define GFD_FEAT_TEMP  0x000000001 //Temperature Feature supported
#define GFD_FEAT_SERV  0x000000002 //Services Switch Feature supported
#define GFD_FEAT_LOG   0x000000004 //SWO Log Feature supported
#define GFD_FEAT_MOTOR   0x000000008 //Motor Feature supported
#define GFD_FEAT_LED   0x000000010 //LED Feature supported
#define GFD_FEAT_TRMOD   0x000000020 //Training Model Upgrade Feature supported
#define GFD_FEAT_ACC   0x000000040 //Accelerate Feature supported
#define GFD_FEAT_GYRO  0x000000080 //Gyroscope Feature supported
#define GFD_FEAT_MAG   0x000000100 //Magnetometer Feature supported
#define GFD_FEAT_EULER   0x000000200 //Euler Angle Feature supported
#define GFD_FEAT_QUAT  0x000000400 //Quaternion Feature supported
#define GFD_FEAT_ROTA  0x000000800 //Rotation Matrix Feature supported
#define GFD_FEAT_GEST  0x000001000 //EMG Gesture Feature supported
#define GFD_FEAT_RAW   0x000002000 //EMG Raw Data Feature supported
#define GFD_FEAT_MOUSE   0x000004000 //HID-Mouse Feature supported
#define GFD_FEAT_JOYSTIC   0x000008000 //HID-Joystick Feature supported
#define GFD_FEAT_STATUS  0x000010000 //Device Status Notify Feature supported
#define GFD_FEAT_MAGANG  0x000080000 //Magnetic Angle Position supported
#define GFD_FEAT_CURRENT   0x000100000 //Motor Current Monitor supported
#define GFD_FEAT_NEUCIRSTAT  0x000200000 //Neucir Status supported
#define GFD_FEAT_EEG       0x000400000 //EEG supported
#define GFD_FEAT_ECG       0x000800000 //ECG supported
#define GFD_FEAT_IMPEDANCE   0x001000000 //Impedance measurement supported
```

### 9.2 setup data types of DataNotify

```obj-c
-(GF_RET_CODE)setDataNotifSwitch:(DataNotifyFlags)flags cb:(onlyResponseCallback)cb timeout:(NSTimeInterval)timeout;
```

Data type list：

```obj-c
typedef NS_ENUM(NSInteger, DataNotifyFlags) {
    /// Data Notify All Off
    DNF_OFF = 0x00000000,

    /// Accelerate On(C.7)
    DNF_ACCELERATE = 0x00000001,

    /// Gyroscope On(C.8)
    DNF_GYROSCOPE = 0x00000002,

    /// Magnetometer On(C.9)
    DNF_MAGNETOMETER = 0x00000004,

    /// Euler Angle On(C.10)
    DNF_EULERANGLE = 0x00000008,

    /// Quaternion On(C.11)
    DNF_QUATERNION = 0x00000010,

    /// Rotation Matrix On(C.12)
    DNF_ROTATIONMATRIX = 0x00000020,

    /// EMG Gesture On(C.13)
    DNF_EMG_GESTURE = 0x00000040,

    /// EMG Raw Data On(C.14)
    DNF_EMG_RAW = 0x00000080,

    /// HID Mouse On(C.15)
    DNF_HID_MOUSE = 0x00000100,

    /// HID Joystick On(C.16)
    DNF_HID_JOYSTICK = 0x00000200,

    /// Device Status On(C.17)
    DNF_DEVICE_STATUS = 0x00000400,

    /// Device Log On
    DNF_LOG = 0x00000800,
    
    DNF_EEG = 0x00010000,
    
    DNF_ECG = 0x00020000,
    
    DNF_IMPEDANCE = 0x00040000,

    /// Data Notify All On
    DNF_ALL = 0xFFFFFFFF,
};
```

It's possible to setup multi data type at same time, and check return data type at callback function.

For example: setup impedance with eeg and ecg.


```java
    DataNotifFlags flags = DNF_IMPEDANCE | DNF_EEG| DNF_ECG;
```

### 9.3 Get data config
Each data type has get/set config function, for example:
EEG data has getEegDataConfig and setEegDataConfig.

```obj-c
-(GF_RET_CODE)setEegDataConfig:(int)sampleRate channelMask:(int)channelMask sampleCount:(int) sampleCount resolutionBits:(int)resolutionBits cb:(onlyResponseCallback)cb timeout:(NSTimeInterval)timeout;

-(GF_RET_CODE)getEegDataConfig:(getSynchronyDataConfigCallback)cb timeout:(NSTimeInterval)timeout;
```

### 9.4 Start data transfer

For start data transfer, use `-(BOOL)startDataNotification` to start. Process data in onSynchronyNotifyData.

```obj-c
- (void)onSynchronyNotifyData:(NSData *)rawData {
    if (rawData.length > 1){
        unsigned char* result = (unsigned char*)rawData.bytes;
        if (result[0] == NTF_EEG || result[0] == NTF_ECG || result[0] == NTF_IMPEDANCE){

            if (result[0] == NTF_EEG){
                synchronyData = self.eegData;
                NSLog(@"got eeg data");
            }
            else if (result[0] == NTF_ECG){
                synchronyData = self.ecgData;
                NSLog(@"got ecg data");
            }
            else if (result[0] == NTF_IMPEDANCE){
                synchronyData = self.impedanceData;
                NSLog(@"got impedance data");
            }
            if (synchronyData == nil){
                return;
            }
        }
    }
}
```

data type：

```obj-c
typedef NS_ENUM(NSInteger, NotifyDataType)  {
    NTF_ACC_DATA = 0x01,
    NTF_GYO_DATA,
    NTF_MAG_DATA,
    NTF_EULER_DATA,
    NTF_QUAT_FLOAT_DATA,
    NTF_ROTA_DATA,
    NTF_EMG_GEST_DATA,
    NTF_EMG_ADC_DATA,
    NTF_HID_MOUSE,
    NTF_HID_JOYSTICK,
    NTF_DEV_STATUS,
    NTF_LOG_DATA,
    NTF_MAG_ANGLE_DATA,
    NTF_MOT_CURRENT_DATA,
    NTF_NEUCIR_STATUS,
    NTF_EEG,
    NTF_ECG,
    NTF_IMPEDANCE,
    NTF_DATA_TYPE_MAX,
    NTF_PARTIAL_DATA = 0xFF
};
```

### 9.5 Stop data transfer

```obj-c
-(BOOL)stopDataNotification;
```
