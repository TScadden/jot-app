package com.notel.notel.data

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.service.HeartRateLoggingService
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers

private const val TAG = "BleManager"

// Standard GATT Heart Rate Service and Characteristic UUIDs
val HEART_RATE_SERVICE_UUID: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
val HEART_RATE_MEASUREMENT_CHAR_UUID: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
val CLIENT_CHARACTERISTIC_CONFIG_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

sealed class ConnectionState {
    object Disconnected : ConnectionState()
    object Scanning : ConnectionState()
    object Connecting : ConnectionState()
    data class Connected(val deviceName: String, val deviceAddress: String) : ConnectionState()
    data class Error(val message: String) : ConnectionState()
}

data class BleDevice(val name: String, val address: String, val device: BluetoothDevice)

class BleManager private constructor(private val context: Context) {

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter

    private val _connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _scannedDevices = MutableStateFlow<List<BleDevice>>(emptyList())
    val scannedDevices: StateFlow<List<BleDevice>> = _scannedDevices.asStateFlow()

    private val _liveHeartRate = MutableStateFlow<Int?>(null)
    val liveHeartRate: StateFlow<Int?> = _liveHeartRate.asStateFlow()

    private val _rawBytes = MutableStateFlow<String?>(null)
    val rawBytes: StateFlow<String?> = _rawBytes.asStateFlow()

    private var bluetoothGatt: BluetoothGatt? = null
    private var isScanning = false
    private var lastConnectedDevice: BleDevice? = null

    private val _isSwitchingConnection = MutableStateFlow(false)
    val isSwitchingConnection: StateFlow<Boolean> = _isSwitchingConnection.asStateFlow()

    fun setSwitchingConnection(value: Boolean) {
        _isSwitchingConnection.value = value
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val name = device.name ?: "Unknown Device"
            val address = device.address
            val bleDevice = BleDevice(name, address, device)

            val currentList = _scannedDevices.value
            if (currentList.none { it.address == address }) {
                _scannedDevices.value = currentList + bleDevice
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed with error code: $errorCode")
            _connectionState.value = ConnectionState.Error("Scan failed: error code $errorCode")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "GATT error status: $status")
                _connectionState.value = ConnectionState.Error("Connection error status: $status")
                disconnect(explicit = false)
                
                // Auto-reconnect on GATT error status
                val deviceToReconnect = lastConnectedDevice
                if (deviceToReconnect != null) {
                    Log.i(TAG, "Auto-reconnect scheduled after GATT error status: $status")
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        if (lastConnectedDevice == deviceToReconnect && (_connectionState.value is ConnectionState.Disconnected || _connectionState.value is ConnectionState.Error)) {
                            connectToDevice(deviceToReconnect)
                        }
                    }, 5000)
                }
                return
            }

            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "Connected to GATT server.")
                    _connectionState.value = ConnectionState.Connected(
                        gatt.device.name ?: "Unknown Device",
                        gatt.device.address
                    )
                    // Start service discovery
                    gatt.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "Disconnected from GATT server.")
                    _connectionState.value = ConnectionState.Disconnected
                    _liveHeartRate.value = null
                    _rawBytes.value = null
                    disconnect(explicit = false)
                    
                    // Auto-reconnect on graceful disconnect
                    val deviceToReconnect = lastConnectedDevice
                    if (deviceToReconnect != null) {
                        Log.i(TAG, "Auto-reconnect scheduled after unexpected disconnection")
                        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                            if (lastConnectedDevice == deviceToReconnect && _connectionState.value is ConnectionState.Disconnected) {
                                connectToDevice(deviceToReconnect)
                            }
                        }, 5000)
                    }
                }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                val service = gatt.getService(HEART_RATE_SERVICE_UUID)
                if (service != null) {
                    val characteristic = service.getCharacteristic(HEART_RATE_MEASUREMENT_CHAR_UUID)
                    if (characteristic != null) {
                        enableHeartRateNotifications(gatt, characteristic)
                    } else {
                        Log.e(TAG, "Heart Rate Measurement characteristic not found!")
                        _connectionState.value = ConnectionState.Error("HR Measurement char not found")
                    }
                } else {
                    Log.e(TAG, "Heart Rate Service not found!")
                    _connectionState.value = ConnectionState.Error("HR Service not found")
                }
            } else {
                Log.e(TAG, "Service discovery failed with status: $status")
                _connectionState.value = ConnectionState.Error("Service discovery failed: $status")
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == HEART_RATE_MEASUREMENT_CHAR_UUID) {
                val data = characteristic.value
                if (data != null && data.isNotEmpty()) {
                    val heartRate = parseHeartRate(data)
                    _liveHeartRate.value = heartRate
                    _rawBytes.value = data.joinToString(" ") { String.format("%02X", it) }
                    Log.d(TAG, "Received Heart Rate: $heartRate")
                }
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            // Support modern API callback signature as well
            if (characteristic.uuid == HEART_RATE_MEASUREMENT_CHAR_UUID) {
                val heartRate = parseHeartRate(value)
                _liveHeartRate.value = heartRate
                _rawBytes.value = value.joinToString(" ") { String.format("%02X", it) }
                Log.d(TAG, "Received Heart Rate: $heartRate")
            }
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.i(TAG, "Notification descriptor written successfully for: ${descriptor.characteristic.uuid}")
            } else {
                Log.e(TAG, "Descriptor write failed with status: $status")
                if (status == 5 || status == 15 || status == 137) {
                    Log.w(TAG, "Device may require pairing/bonding to access Heart Rate data. Attempting bond: ${gatt.device.bondState}")
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    fun startScanning() {
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            _connectionState.value = ConnectionState.Error("Bluetooth not enabled or supported")
            return
        }

        if (isScanning) return

        _scannedDevices.value = emptyList()
        _connectionState.value = ConnectionState.Scanning
        isScanning = true

        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(HEART_RATE_SERVICE_UUID))
            .build()

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        try {
            // Instantly list any devices already connected to the system
            val connectedDevices = bluetoothManager.getConnectedDevices(BluetoothProfile.GATT)
            val currentList = _scannedDevices.value.toMutableList()
            for (device in connectedDevices) {
                val name = device.name ?: "Connected Band/Sensor"
                val address = device.address
                if (currentList.none { it.address == address }) {
                    currentList.add(BleDevice(name, address, device))
                }
            }
            _scannedDevices.value = currentList
        } catch (e: SecurityException) {
            Log.e(TAG, "Permission denied to read connected devices", e)
        }

        try {
            bluetoothAdapter.bluetoothLeScanner?.startScan(listOf(filter), settings, scanCallback)
        } catch (e: SecurityException) {
            _connectionState.value = ConnectionState.Error("Permission denied: Bluetooth Scan")
            isScanning = false
        }
    }

    @SuppressLint("MissingPermission")
    fun stopScanning() {
        if (!isScanning) return
        isScanning = false
        if (_connectionState.value is ConnectionState.Scanning) {
            _connectionState.value = ConnectionState.Disconnected
        }

        try {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (e: SecurityException) {
            Log.e(TAG, "Failed to stop scan due to permissions", e)
        }
    }

    @SuppressLint("MissingPermission")
    fun connectToDevice(bleDevice: BleDevice) {
        stopScanning()
        _connectionState.value = ConnectionState.Connecting
        lastConnectedDevice = bleDevice
        _isSwitchingConnection.value = false // Done switching connection

        try {
            bluetoothGatt = bleDevice.device.connectGatt(context, false, gattCallback)
        } catch (e: SecurityException) {
            _connectionState.value = ConnectionState.Error("Permission denied: Bluetooth Connect")
        }
    }

    @SuppressLint("MissingPermission")
    fun disconnect(explicit: Boolean = false) {
        if (explicit) {
            lastConnectedDevice = null
            _isSwitchingConnection.value = false
        }
        try {
            bluetoothGatt?.let {
                it.disconnect()
                it.close()
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "Failed to disconnect due to permissions", e)
        }
        bluetoothGatt = null
        _liveHeartRate.value = null
        _rawBytes.value = null
        if (_connectionState.value !is ConnectionState.Disconnected && _connectionState.value !is ConnectionState.Error) {
            _connectionState.value = ConnectionState.Disconnected
        }
    }

    @SuppressLint("MissingPermission")
    private fun enableHeartRateNotifications(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        gatt.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CLIENT_CHARACTERISTIC_CONFIG_UUID)
        if (descriptor != null) {
            // Write descriptor to enable notifications
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            gatt.writeDescriptor(descriptor)
            
            // Trigger bonding if not bonded (common requirement for smartwatches like Fitbit Air)
            if (gatt.device.bondState == android.bluetooth.BluetoothDevice.BOND_NONE) {
                Log.i(TAG, "Device is not bonded. Initiating pairing/bonding...")
                gatt.device.createBond()
            }
        }
    }

    private var isAutoScanning = false

    private fun parseHeartRate(data: ByteArray): Int {
        val flags = data[0].toInt()
        val isHeartRate16Bit = (flags and 0x01) != 0
        return if (isHeartRate16Bit) {
            val byte1 = data[1].toInt() and 0xFF
            val byte2 = data[2].toInt() and 0xFF
            (byte2 shl 8) or byte1
        } else {
            data[1].toInt() and 0xFF
        }
    }

    @SuppressLint("MissingPermission")
    fun scanAndAutoStart(context: Context, preferences: NotelPreferences) {
        val adapter = bluetoothAdapter
        if (adapter == null || !adapter.isEnabled) return

        if (HeartRateLoggingService.isServiceRunning.value) return

        val hasScan = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            context.checkSelfPermission(android.Manifest.permission.BLUETOOTH_SCAN) == android.content.pm.PackageManager.PERMISSION_GRANTED &&
            context.checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            context.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        if (!hasScan) return

        CoroutineScope(Dispatchers.IO).launch {
            val autoConnect = preferences.bleAutoConnectEnabled.first()
            if (!autoConnect) return@launch

            val lastAddress = preferences.lastConnectedDeviceAddress.first()
            val lastName = preferences.lastConnectedDeviceName.first()

            try {
                val connectedDevices = bluetoothManager.getConnectedDevices(BluetoothProfile.GATT)
                val match = connectedDevices.find {
                    val name = it.name ?: ""
                    name.contains("Visible", ignoreCase = true) || it.address == lastAddress
                }
                if (match != null) {
                    val finalName = match.name ?: lastName.ifBlank { "Visible Band" }
                    launchStartService(context, match.address, finalName)
                    return@launch
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error checking system connected devices", e)
            }

            kotlinx.coroutines.withContext(Dispatchers.Main) {
                if (isAutoScanning) return@withContext

                isAutoScanning = true
                val filter = ScanFilter.Builder()
                    .setServiceUuid(ParcelUuid(HEART_RATE_SERVICE_UUID))
                    .build()

                val settings = ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_POWER)
                    .build()

                val autoStartScanCallback = object : ScanCallback() {
                    override fun onScanResult(callbackType: Int, result: ScanResult) {
                        val dev = result.device
                        val name = dev.name ?: ""
                        if (name.contains("Visible", ignoreCase = true) || dev.address == lastAddress) {
                            try {
                                adapter.bluetoothLeScanner?.stopScan(this)
                            } catch (e: SecurityException) {}
                            isAutoScanning = false
                            launchStartService(context, dev.address, if (name.isBlank()) lastName.ifBlank { "Visible Band" } else name)
                        }
                    }
                }

                try {
                    adapter.bluetoothLeScanner?.startScan(listOf(filter), settings, autoStartScanCallback)
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        if (isAutoScanning) {
                            try {
                                adapter.bluetoothLeScanner?.stopScan(autoStartScanCallback)
                            } catch (e: SecurityException) {}
                            isAutoScanning = false
                        }
                    }, 10000)
                } catch (e: SecurityException) {
                    isAutoScanning = false
                }
            }
        }
    }

    private fun launchStartService(context: Context, address: String, name: String) {
        val intent = android.content.Intent(context, HeartRateLoggingService::class.java).apply {
            action = HeartRateLoggingService.ACTION_START
            putExtra(HeartRateLoggingService.EXTRA_DEVICE_ADDRESS, address)
            putExtra(HeartRateLoggingService.EXTRA_DEVICE_NAME, name)
        }
        androidx.core.content.ContextCompat.startForegroundService(context, intent)
        Log.i(TAG, "Auto-started HeartRateLoggingService for $name ($address)")
    }

    companion object {
        @Volatile
        private var INSTANCE: BleManager? = null

        fun getInstance(context: Context): BleManager {
            return INSTANCE ?: synchronized(this) {
                val instance = BleManager(context.applicationContext)
                INSTANCE = instance
                instance
            }
        }
    }
}
