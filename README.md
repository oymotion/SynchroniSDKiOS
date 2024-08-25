# Synchroni SDK + swift demo

## Brief
Synchroni SDK is the software development kit for developers to access OYMotion Synchroni products.
## 1. Permission 

Application will obtain bluetooth permission by itself. 

## 2. Import SDK

```swift
import sensor

```

## 3. Initalize

```swift
//ViewController.swift

class SensorDataContext : SensorProfileDelegate{
    public var profile: SensorProfile
    public var lastEEG: SensorData?
    public var lastECG: SensorData?
    public var lastBRTH: SensorData?
    public var lastACC: SensorData?
    public var lastGYRO: SensorData?
    public var lastError: Error?
}

class ViewController: UIViewController , SensorControllerDelegate {
    private var controller: SensorController?
    private var sensorDataCtxs: [String : SensorDataContext] = [:]
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        controller = SensorController.getInstance()
        controller?.delegate = self
    }
}

```

## 4. Start scan

```swift
SensorController.startScan(TIMEOUT)
```

`onSensorScanResult(_ bleDevices: [BLEPeripheral])` 
returns array of BLEPeripheral

```swift
    for bleDevice in bleDevices {
        if (bleDevice.name.hasPrefix("SYNC")){
            if (sensorDataCtxs[bleDevice.macAddress] == nil){
                let sensorProfile = controller.getSensor(bleDevice.macAddress);
                let sensorDataCtx = SensorDataContext(profile : sensorProfile)
                sensorDataCtxs[bleDevice.macAddress] = sensorDataCtx;
                print("Found: " + bleDevice.name + " : " + String(bleDevice.rssi.intValue))
            }
        }
    }
```

## 5. Stop scan

```swift
SensorController.stopScan()
```


## 6. Connect device


```swift
SensorProfile.connect()
```

## 7. Disconnect

```swift
SensorProfile.disconnect()
```


## 8. Get device status

```swift
SensorProfile.state;
```

Please send command in 'BLEState.ready'

```swift
typedef NS_ENUM(NSInteger, BLEState)
{
    BLEStateUnConnected,
    BLEStateConnecting,
    BLEStateConnected,
    BLEStateReady,
    BLEStateInvalid,
};
```

## 9. DataNotify

### 9.1 init data notify

```swift
SensorProfile.initAll(PACKAGE_COUNT, timeout: TIMEOUT)
```

### 9.2 Start data transfer

For start data transfer, use `-(BOOL)startDataNotification` to start. Process data in onSensorNotify.

```swift
SensorProfile.startDataNotification()

func onSensorNotify(_ rawData: SensorData!) {
    if (rawData.dataType == NotifyDataType.NTF_EEG){
        lastEEG = rawData
    } else if (rawData.dataType == NotifyDataType.NTF_ECG){

    }else if (rawData.dataType == NotifyDataType.NTF_ACC_DATA){

    }else if (rawData.dataType == NotifyDataType.NTF_GYO_DATA){

    }else if (rawData.dataType == NotifyDataType.NTF_BRTH){

    }
}

```

data type：

```swift
typedef NS_ENUM(NSInteger, NotifyDataType)  {
    NTF_ACC_DATA,
    NTF_GYO_DATA,
    NTF_EEG,
    NTF_ECG,
    NTF_BRTH,
};
```

### 9.3 Stop data transfer

```swift
SensorProfile.stopDataNotification;
```
