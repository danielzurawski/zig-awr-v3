"""Stub for vendor Server/RPIservo.py — implements the ServoCtrl surface used by WebServer.py."""

import threading


class ServoCtrl(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.initPos = [90, 90, 90, 90, 90]
        self.scTime = 0.05

    def moveInit(self):
        pass

    def initConfig(self, *args, **kwargs):
        pass

    def positionChange(self, *args, **kwargs):
        pass

    def moveAngle(self, *args, **kwargs):
        pass

    def setPWM(self, *args, **kwargs):
        pass

    def singleServo(self, *args, **kwargs):
        pass

    def stopWiggle(self):
        pass

    def turnLeft(self, *args, **kwargs):
        pass

    def turnRight(self, *args, **kwargs):
        pass

    def turnMiddle(self):
        pass

    def moveServoInit(self, *args, **kwargs):
        pass

    def run(self):
        # No background work — vendor expects a long-running thread,
        # but we just exit cleanly so nothing is busy-waiting.
        pass
