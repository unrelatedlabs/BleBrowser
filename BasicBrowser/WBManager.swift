//
//  WebBluetooth.swift
//  BasicBrowser
//
//  Copyright 2016-2017 Paul Theriault and David Park. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import Foundation
import CoreBluetooth
import WebKit

open class WBManager: NSObject, CBCentralManagerDelegate, WKScriptMessageHandler, PopUpPickerViewDelegate {

    // MARK: - Embedded types
    enum ManagerRequests: String {
        case device, requestDevice
    }

    // MARK: - Properties
    let debug = true
    let centralManager = CBCentralManager(delegate: nil, queue: nil)
    var devicePicker: PopUpPickerView!

    /*! @abstract The devices selected by the user for use by this manager. Keyed by the UUID provided by the system. */
    var devicesByInternalUUID = [UUID: WBDevice]()

    /*! @abstract The devices selected by the user for use by this manager. Keyed by the UUID we create and pass to the web page. This seems to be for security purposes, and seems sensible. */
    var devicesByExternalUUID = [UUID: WBDevice]()

    /*! @abstract The outstanding request for a device from the web page, if one is outstanding. Ony one may be outstanding at any one time and should be policed by a modal dialog box. TODO: how modal is the current solution?
     */
    var requestDeviceTransaction: WBTransaction? = nil

    /*! @abstract Filters in use on the current device request transaction.  If nil, that means we are accepting all devices.
     */
    var filters: [[String: AnyObject]]? = nil
    var pickerDevices = [WBDevice]()

    // MARK: - Constructors / destructors
    override init() {
        super.init()
        self.centralManager.delegate = self
    }
    deinit {
        NSLog("WBManager deinit")
        self.clearState()
    }

    // MARK: - WKScriptMessageHandler
    open func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {

        guard let trans = WBTransaction(withMessage: message) else {
            /* The transaction will have handled the error */
            return
        }
        self.triage(transaction: trans)
    }

    // MARK: - CBCentralManagerDelegate
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        NSLog("Bluetooth is \(central.state == CBManagerState.poweredOn ? "ON" : "OFF")")
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {

        if let filters = self.filters,
            !self._peripheral(peripheral, isIncludedBy: filters) {
            return
        }
        
        let device = WBDevice(
            peripheral: peripheral, advertisementData: advertisementData,
            RSSI: RSSI, manager: self)
        if !self.pickerDevices.contains(where: {$0 == device}) {
            self.pickerDevices.append(device)
            self.updatePickerData()
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard
            let device = self.devicesByInternalUUID[peripheral.identifier]
        else {
            NSLog("Unexpected didConnect notification for \(peripheral.name ?? "<no-name>") \(peripheral.identifier)")
            return
        }
        device.didConnect()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard
            let device = self.devicesByInternalUUID[peripheral.identifier]
            else {
                NSLog("Unexpected didDisconnect notification for unknown device \(peripheral.name ?? "<no-name>") \(peripheral.identifier)")
                return
        }
        device.didDisconnect(error: error)
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnectPeripheral peripheral: CBPeripheral) {
        NSLog("FAILED TO CONNECT PERIPHERAL UNHANDLED")
        
    }
    
    // MARK: - PopUpPickerViewDelegate
    public var numberOfItems: Int {
        get {
            return self.pickerDevices.count
        }
    }

    public func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        // dummy response for making screen shots from the simulator
        // return row == 0 ? "Puck.js 69c5 (82DF60A5-3C0B..." : "Puck.js c728 (9AB342DA-4C27..."
        return self._pv(pickerView, titleForRow: row, forComponent: component)
    }
    
    public func pickerView(_ pickerView: UIPickerView, didSelect numbers: [Int]) {

        guard
            numbers.count > 0,
            let index = Optional(numbers[0]),
            self.pickerDevices.count > index
        else {
            NSLog("Invalid device selection \(numbers), try again")
            self.devicePicker.showPicker()
            return
        }

        let device = self.pickerDevices[index]
        device.view = self.requestDeviceTransaction?.webView
        self.requestDeviceTransaction?.resolveAsSuccess(withObject: device)
        self.deviceWasSelected(device)

    }
    public func pickerViewCancelled(_ pickerView: UIPickerView) {
        NSLog("User cancelled device selection.")
        self.requestDeviceTransaction?.resolveAsFailure(withMessage: "User cancelled")
        self.pickerDevices = []
        self.updatePickerData()
    }
    public func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    public func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        // dummy response for making screen shots from the simulator
        // return 2
        return self.pickerDevices.count
    }
    
    // MARK: - Private
    private func triage(transaction: WBTransaction){

        guard
            transaction.key.typeComponents.count > 0,
            let managerMessageType = ManagerRequests(
                rawValue: transaction.key.typeComponents[0])
        else {
            transaction.resolveAsFailure(withMessage: "Request type components not recognised \(transaction.key)")
            return
        }

        switch managerMessageType
        {
        case .device:

            guard let view = WBDevice.DeviceTransactionView(transaction: transaction) else {
                transaction.resolveAsFailure(withMessage: "Bad device request")
                break
            }

            let devUUID = view.externalDeviceUUID
            guard let device = self.devicesByExternalUUID[devUUID]
                else {
                    transaction.resolveAsFailure(withMessage: "No known device for device transaction \(transaction)")
                    break
            }
            device.triage(transaction: transaction)
        case .requestDevice:
            guard transaction.key.typeComponents.count == 1
            else {
                transaction.resolveAsFailure(withMessage: "Invalid request type \(transaction.key)")
                break
            }
            let acceptAllDevices = transaction.messageData["acceptAllDevices"] as? Bool ?? false

            let filters = transaction.messageData["filters"] as? [[String: AnyObject]]

            // PROTECT force unwrap see below
            guard acceptAllDevices || filters != nil
            else {
                transaction.resolveAsFailure(withMessage: "acceptAllDevices false but no filters passed: \(transaction.messageData)")
                break
            }
            guard self.requestDeviceTransaction == nil
            else {
                transaction.resolveAsFailure(withMessage: "Previous device request is still in progress")
                break
            }

            if self.debug {
                NSLog("Requesting device with filters \(filters?.description ?? "nil")")
            }

            self.requestDeviceTransaction = transaction
            if acceptAllDevices {
                self.scanForAllPeripherals()
            }
            else {
                // force unwrap, but protected by guard above marked PROTECT
                self.scanForPeripherals(with: filters!)
            }
            transaction.addCompletionHandler {_, _ in
                self.stopScanForPeripherals()
                self.requestDeviceTransaction = nil
            }
            self.devicePicker.showPicker()
        }
    }

    func clearState() {
        self.stopScanForPeripherals()
        self.requestDeviceTransaction?.abandon()
        self.requestDeviceTransaction = nil
        // the external and internal devices are the same, but tidier to do this in one loop; calling clearState on a device twice is OK.
        for var devMap in [self.devicesByExternalUUID, self.devicesByInternalUUID] {
            for (_, device) in devMap {
                device.clearState()
            }
            devMap.removeAll()
        }
        self.pickerDevices = []
    }

    private func deviceWasSelected(_ device: WBDevice) {
        // TODO: think about whether overwriting any existing device is an issue.
        self.devicesByExternalUUID[device.deviceId] = device;
        self.devicesByInternalUUID[device.internalUUID] = device;
    }

    func scanForAllPeripherals() {
        self.pickerDevices.removeAll()
        self.filters = nil
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }

    func scanForPeripherals(with filters:[[String: AnyObject]]) {

        let services = filters.reduce([String](), {
            (currReduction, nextValue) in
            if let nextServices = nextValue["services"] as? [String] {
                return currReduction + nextServices
            }
            return currReduction
        })

        let servicesCBUUID = self._convertServicesListToCBUUID(services)

        if (self.debug) {
            NSLog("Scanning for peripherals... (services: \(servicesCBUUID))")
        }
        
        self.pickerDevices = [];
        self.filters = filters
        centralManager.scanForPeripherals(withServices: servicesCBUUID, options: nil)
    }
    func stopScanForPeripherals() {
        if self.centralManager.state == .poweredOn {
            self.centralManager.stopScan()
        }
        self.pickerDevices.removeAll()
    }
    
    func updatePickerData(){
        self.pickerDevices.sort(by: {
            if $0.name != nil && $1.name == nil {
                // $1 is "bigger" in that its name is nil
                return true
            }
            // cannot be sorting ids that we haven't discovered
            if $0.name == $1.name {
                return $0.internalUUID.uuidString < $1.internalUUID.uuidString
            }
            if $0.name == nil {
                // $0 is "bigger" as it's nil and the other isn't
                return false
            }
            // forced unwrap protected by logic above
            return $0.name! < $1.name!
        })
        self.devicePicker.updatePicker()
    }

    private func _convertServicesListToCBUUID(_ services: [String]) -> [CBUUID] {
        return services.map {
            servStr -> CBUUID? in
            guard let uuid = UUID(uuidString: servStr.uppercased()) else {
                return nil
            }
            return CBUUID(nsuuid: uuid)
            }.filter{$0 != nil}.map{$0!};
    }

    private func _peripheral(_ peripheral: CBPeripheral, isIncludedBy filters: [[String: AnyObject]]) -> Bool {
        for filter in filters {
            if let pname = peripheral.name {
                if let namePrefix = filter["namePrefix"] as? String {
                    if pname.hasPrefix(namePrefix) { return true }
                }
                if let name = filter["name"] as? String {
                    if pname == name { return true }
                }
            }
        }
        return false
    }

    private func _pv(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String {

        let dev = self.pickerDevices[row]
        let id = dev.internalUUID
        guard let name = dev.name
            else {
                return "(\(id))"
        }
        return "\(name) (\(id))"
    }
}
