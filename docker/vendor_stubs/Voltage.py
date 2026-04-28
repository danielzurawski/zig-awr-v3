"""Stub for vendor Server/Voltage.py — the BatteryLevelMonitor used by WebServer.py."""

import threading


class BatteryLevelMonitor(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.battery_voltage = 7.4

    def start(self):
        pass

    def getBatteryLevel(self):
        return self.battery_voltage

    def run(self):
        pass
