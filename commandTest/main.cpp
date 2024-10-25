//
//  main.cpp
//  mactest
//
//  Created by 叶常青 on 2024/10/18.
//

#include <iostream>
#include <thread>
#include <map>
#include <sensor/SensorController.hpp>

using namespace std;
using namespace sensor;

class TestController: public SensorControllerDelegate, public SensorProfileDelegate, public enable_shared_from_this<TestController>
{
public:
    map<shared_ptr<SensorProfile>, SensorData> dataCtx;
    
    virtual void onSensorControllerEnableChanged(bool enabled){
        if (enabled){
            cout << "Start scan2!\n";
            auto controller = SensorController::getInstance();
            if (!controller->isScaning()){
                controller->startScan(5000);
            }
        }
    }
    
    virtual void onSensorScanResult(vector<BLEDevice> bleDevices){
        auto self = shared_from_this();
        auto controller = SensorController::getInstance();
        for(auto device : bleDevices){
            if (device.name.starts_with("OB") || device.name.starts_with("Sync")){
                cout << device.name << " -> " << device.rssi << endl;
                auto profile = controller->getSensor(device.mac);
                profile->setDelegate(self);
                profile->connect();
            }
        }
        cout << "Total " << bleDevices.size() << endl;
        if (!bleDevices.empty()){
            controller->stopScan();
        }
    }
    
    virtual void onErrorCallback(shared_ptr<SensorProfile> profile, string errorMsg) {
        cout << profile->getDevice().name << " got error: " << errorMsg << endl;
    };
    
    virtual void onStateChange(shared_ptr<SensorProfile> profile, BLEDevice::State newState) {
        auto self = shared_from_this();
        if (newState == sensor::BLEDevice::Ready){
            cout << profile->getDevice().name << " ready" << endl;
            profile->init(10, 5000, [self, profile](bool result, string err){
                if (result){
                    profile->fetchDeviceInfo(5000, [self, profile](DeviceInfo info, string err){
                        if (err != ""){
                            cout << "error in get device info: " << err << endl;
                        }else{
                            cout << "device info: " << info.firmwareVersion << endl;
                        }
                        profile->startDataNotification(5000, [](bool result, string err){
                            cout << "start data: " << result << endl;
                        });
                    });
                }else{
                    cout << "init fail: " << err << endl;
                }
            });
        }else if (newState == sensor::BLEDevice::Disconnected){
            cout << profile->getDevice().name << " disconnected" << endl;
            exit(0);
        }
        
    };
    virtual void onSensorNotifyData(shared_ptr<SensorProfile> profile, const SensorData& rawData) {
        if (rawData.dataType == sensor::SensorData::NTF_EEG){
            dataCtx[profile] = rawData;
            cout << profile->getDevice().name << " got eeg: " << rawData.channelSamples.size() << endl;
            for (auto& samplesInOneChannel : rawData.channelSamples){
                for (auto& sample : samplesInOneChannel){
                    //do process
                }
            }
            profile->stopDataNotification(5000, [profile](bool result, string err){
                cout << "stop data: " << result << endl;
                profile->getBatteryLevel(5000, [profile](int battery, string err){
                    cout << profile->getDevice().name << " battery: " << battery << endl;
                    profile->disconnect();
                });
            });
        }
    };
};

int main(int argc, const char * argv[]) {
    // insert code here...
    cout << "Hello, World!\n";
    
    auto controller = SensorController::getInstance();
    auto delegate = make_shared<TestController>(TestController());
    controller->setDelegate(delegate);
    if (controller->isEnable()){
        cout << "Start scan1!\n";
        controller->startScan(5000);
    }
    
    do{
        string cmd;
        cin >> cmd;
        if (cmd[0] == 'c'){
            break;
        }
    }while(true);
    return 0;
}
