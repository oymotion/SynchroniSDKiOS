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
let DEBUG = false

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
    
    func onSensorErrorCallback(_ profile: SensorProfile, err: Error) {
        lastError = err;
    }
    
    func onSensorStateChange(_ profile: SensorProfile, newState: BLEState) {
        print("Device: " + profile.device.name + " state: " + profile.stateString)
        if (newState == BLEState.unConnected || newState == BLEState.invalid){
            print("Reset device: " + profile.device.name);
            clear()
        }else if (newState == BLEState.ready && !profile.hasInit){
            Task{
                if (!profile.hasInit){
                    if (DEBUG){
                        let debugBLEPath = NSTemporaryDirectory() + "/ble_data_log_" + profile.device.name + ".csv";

                        let result = try await profile.setParam(TIMEOUT, key:"DEBUG_BLE_DATA_PATH", value:debugBLEPath);
                        print("set debug ble result: " + debugBLEPath + " => " + result);
                    }

                    do{
                        let hasInit = try await profile.initAll(PACKAGE_COUNT, timeout: TIMEOUT)
                        if (hasInit){
                            print("Init " + profile.device.macAddress + " succeed");
                        }else{
                            print("Init " + profile.device.macAddress + " fail");
                        }
                        
                    }catch{
                        print("init fail with result: \(error)")
                    }
                }
            }
        }

    }
    
    func onSensorNotifyData(_ profile: SensorProfile, rawData: SensorData) {
        if (rawData.dataType == NotifyDataType.NTF_EEG){
//            print(profile.device.name + " => Got EEG data: " + String(rawData.channelSamples[0][0].timeStampInMs));
            for sensorData in rawData.channelSamples[0] {
                print(String(sensorData.sampleIndex))
                if ((sensorData.sampleIndex % 10) == 0){
                    if (DEBUG){
                        profile.setParam(TIMEOUT, key: "FLUSH_BLE_DATA", value: "", completion: { (_:String?,_:Error?)in
                                                
                                            })
                    }
                }
            }

            
//            lastEEG = rawData
            
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
//        deviceText.text = "scaning"
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

                    let deviceInfo = try await sensorData.value.profile.deviceInfo(false,timeout:TIMEOUT)
                    if (deviceInfo != nil){
                        print("deviceInfo: " + deviceInfo!.modelName + " : " + deviceInfo!.firmwareVersion)
                    }else{
                        print("Get deviceInfo fail: "  + sensorData.value.profile.device.name)
                    }
                
                    let battery = try await sensorData.value.profile.battery(TIMEOUT)
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
                if (sensorData.value.profile.hasInit){
                    do{
                        if (sensorData.value.profile.hasStartDataNotification){
                            try await sensorData.value.profile.stopDataNotification(TIMEOUT);
                        }else{
                            try await sensorData.value.profile.startDataNotification(TIMEOUT);
                        }
                        print("set data notify result: " + String(sensorData.value.profile.hasStartDataNotification));
                    }catch{
                        
                    }
                }
            }
        }
    }
    
    func onSensorControllerEnableChange(_ enabled: Bool) {
        if (enabled){
            if (controller!.isScaning){
                controller!.stopScan()
            }else{
                controller!.startScan(TIMEOUT)
            }
        }
    }
    
    func onSensorScanResult(_ bleDevices: [BLEPeripheral]) {
        print("onSensorScanResult")
        for bleDevice in bleDevices {
            if (bleDevice.name.hasPrefix("OB") || bleDevice.name.hasPrefix("SYNC") || bleDevice.name.hasPrefix("Sync")){
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


