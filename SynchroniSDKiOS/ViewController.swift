//
//  ViewController.swift
//  test
//
//  Created by 叶常青 on 2024/4/18.
//

import UIKit
import sensor

let PACKAGE_COUNT = Int32(16)
let TIMEOUT = TimeInterval(6)

class SensorDataContext : SensorProfileDelegate{
    public var profile: SensorProfile
    public var lastEEG: SensorData?
    public var lastECG: SensorData?
    public var lastBRTH: SensorData?
    public var lastACC: SensorData?
    public var lastGYRO: SensorData?
    public var lastError: Error?
    
    init(profile: SensorProfile!) {
        self.profile = profile;
        profile.delegate = self
    }
    
    func onSensorErrorCallback(_ err: Error!) {
        lastError = err;
    }
    
    func onSensorStateChange(_ newState: BLEState) {
        print("Device: " + profile.device.name + " state: " + profile.stateString)
        if (newState == BLEState.unConnected || newState == BLEState.invalid){
            print("Reset device: " + profile.device.name);
            clear()
        }else if (newState == BLEState.ready && !profile.hasInit){
            Task{
                if (!profile.hasInit){
                    let hasInit = await profile.initAll(PACKAGE_COUNT, timeout: TIMEOUT)
                    if (hasInit){
                        print("Init " + profile.device.macAddress + " succeed");
                    }else{
                        print("Init " + profile.device.macAddress + " fail");
                    }
                }
            }
        }
    }
    
    func onSensorNotify(_ rawData: SensorData!) {
        if (rawData.dataType == NotifyDataType.NTF_EEG){
//            print(profile.device.name + " => Got EEG data: " + String(rawData.channelSamples[0][0].timeStampInMs));
            for sensorData in rawData.channelSamples[0] {
                print(String(sensorData.sampleIndex))
            }

            lastEEG = rawData
            
            //please check following properies
//            lastEEG?.channelSamples[0][0].timeStampInMs
//            lastEEG?.channelSamples[0][0].isLost
//            lastEEG?.channelSamples[0][0].convertData
//            lastEEG?.channelSamples[0][0].impedance
            
        }else if (rawData.dataType == NotifyDataType.NTF_ECG){
//            print(profile.device.name + " => Got ECG data: " + String(rawData.channelSamples[0][0].timeStampInMs));
//            lastECG = rawData
        }else if (rawData.dataType == NotifyDataType.NTF_ACC_DATA){
//            print(profile.device.name + " => Got ACC data: " + String(rawData.channelSamples[0][0].timeStampInMs));
//            lastACC = rawData
        }else if (rawData.dataType == NotifyDataType.NTF_GYO_DATA){
//            print(profile.device.name + " => Got GYRO data: " + String(rawData.channelSamples[0][0].timeStampInMs));
//            lastGYRO = rawData
        }else if (rawData.dataType == NotifyDataType.NTF_BRTH){
//            print(profile.device.name + " => Got Brth data: " + String(rawData.channelSamples[0][0].timeStampInMs));
//            lastBRTH = rawData;
        }
        
    }
    
    func clear(){
        lastEEG = nil
        lastECG = nil
        lastBRTH = nil
        lastACC = nil
        lastGYRO = nil
        lastError = nil
    }
}

class ViewController: UIViewController , SensorControllerDelegate {
    private var controller: SensorController?
    private var sensorDataCtxs: [String : SensorDataContext] = [:]
    private var hasStartDataTransfer = false


    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        controller = SensorController.getInstance()
        controller?.delegate = self
    }

    @IBAction func onScan(_ sender: Any) {
        if (!controller!.isEnable){
            print("Please open blue tooth")
            return
        }
        if (controller!.isScaning){
            controller!.stopScan()
        }else{
            controller!.startScan(TIMEOUT)
        }
        
    }

    @IBAction func onConnect(_ sender: Any) {
        for sensorData in sensorDataCtxs {
            if (sensorData.value.profile.state == BLEState.ready){
                sensorData.value.profile.disconnect()
            }else{
                sensorData.value.profile.connect()
            }
        }
    }

    @IBAction func onVersion(_ sender: Any) {
        Task{
            for sensorData in self.sensorDataCtxs {
                if (sensorData.value.profile.state == BLEState.ready){
                    let deviceInfo = await sensorData.value.profile.deviceInfo(false,timeout:TIMEOUT)
                    if (deviceInfo != nil){
                        print("deviceInfo: " + deviceInfo!.modelName + " : " + deviceInfo!.firmwareVersion)
                    }else{
                        print("Get deviceInfo fail: "  + sensorData.value.profile.device.name)
                    }
                
                    let battery = await sensorData.value.profile.battery(TIMEOUT)
                    if (battery >= 0){
                        print("Battery: " + sensorData.value.profile.device.name + " : " + String(battery))
                    }else{
                        print("Get battery fail: "  + sensorData.value.profile.device.name)
                    }
                }
            }
        }
    }

    @IBAction func onTest(_ sender: Any) {
        Task{
            for sensorData in self.sensorDataCtxs {
                if (sensorData.value.profile.state == BLEState.ready){
                    if (sensorData.value.profile.hasStartDataNotification){
                        await sensorData.value.profile.stopDataNotification(TIMEOUT);
                    }else{
                        await
                            sensorData.value.profile.startDataNotification(TIMEOUT);
                    }
                    print("set data notify result: " + String(sensorData.value.profile.hasStartDataNotification));
                }
            }
        }
    }
    
    func onSensorScanResult(_ bleDevices: [BLEPeripheral]) {
        print("onSensorScanResult")
        for bleDevice in bleDevices {
            if (bleDevice.name.hasPrefix("OB") || bleDevice.name.hasPrefix("SYNC")){
                if (sensorDataCtxs[bleDevice.macAddress] == nil){
                    let sensorProfile = controller?.getSensor(bleDevice.macAddress);
                    let sensorDataCtx = SensorDataContext(profile : sensorProfile)
                    sensorDataCtxs[bleDevice.macAddress] = sensorDataCtx;
                    print("Found: " + bleDevice.name + " : " + String(bleDevice.rssi.intValue))
                }
            }
        }
    }
}


