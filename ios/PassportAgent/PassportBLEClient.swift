@preconcurrency import CoreBluetooth
import Foundation
import Observation

@MainActor
@Observable
final class PassportBLEClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "8F5B0001-6F57-4E28-9B5D-6D1D6F7A1000")
    static let commandUUID = CBUUID(string: "8F5B0002-6F57-4E28-9B5D-6D1D6F7A1000")
    static let replyUUID = CBUUID(string: "8F5B0003-6F57-4E28-9B5D-6D1D6F7A1000")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var replyCharacteristic: CBCharacteristic?
    private var pending: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    var status = "未连接"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: "PassportAgentCentral"])
    }

    func connect() {
        guard central.state == .poweredOn else { return }
        status = "正在搜索"
        central.scanForPeripherals(withServices: nil)
    }

    func send(_ command: String) async throws -> String {
        guard command.utf8.count < 256, !command.contains("\n"),
              let peripheral, let characteristic = commandCharacteristic else { throw BLEError.notReady }
        guard pending == nil else { throw BLEError.busy }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            peripheral.writeValue(Data(command.utf8), for: characteristic, type: .withResponse)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.finish(.failure(BLEError.timeout))
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { connect() } else { status = "蓝牙不可用" }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let passport = restored.first(where: { $0.name == "AI Passport" }) ?? restored.first else {
            return
        }
        peripheral = passport
        passport.delegate = self
        if passport.state == .connected {
            status = "正在恢复连接"
            passport.discoverServices([Self.serviceUUID])
        } else {
            status = "正在重新连接"
            central.connect(passport)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripheral.name == "AI Passport" || (advertisementData[CBAdvertisementDataLocalNameKey] as? String) == "AI Passport" else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status = "正在连接"
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "正在发现服务"
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        status = "连接已断开"
        commandCharacteristic = nil
        replyCharacteristic = nil
        finish(.failure(error ?? BLEError.disconnected))
        connect()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { status = "未找到控制服务"; return }
        peripheral.discoverCharacteristics([Self.commandUUID, Self.replyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { status = "服务发现失败"; return }
        commandCharacteristic = service.characteristics?.first { $0.uuid == Self.commandUUID }
        replyCharacteristic = service.characteristics?.first { $0.uuid == Self.replyUUID }
        if let replyCharacteristic { peripheral.setNotifyValue(true, for: replyCharacteristic) }
        status = commandCharacteristic == nil || replyCharacteristic == nil ? "控制服务不完整" : "已连接"
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { finish(.failure(error)); return }
        guard characteristic.uuid == Self.replyUUID, let data = characteristic.value,
              let reply = String(data: data, encoding: .utf8) else { return }
        finish(.success(reply))
    }

    private func finish(_ result: Result<String, Error>) {
        timeoutTask?.cancel(); timeoutTask = nil
        guard let pending else { return }
        self.pending = nil
        pending.resume(with: result)
    }
}

enum BLEError: LocalizedError { case notReady, busy, timeout, disconnected }
