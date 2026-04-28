"""Stub for vendor Server/app.py — replaces the Flask camera webapp."""


class _StubCamera:
    def colorSet(self, *args, **kwargs):
        pass

    def linePosSet_1(self, *args, **kwargs):
        pass

    def linePosSet_2(self, *args, **kwargs):
        pass

    def errorSet(self, *args, **kwargs):
        pass


class webapp:
    def __init__(self):
        self.camera = _StubCamera()

    def startthread(self):
        pass

    def colorFindSet(self, *args, **kwargs):
        pass

    def modeselect(self, *args, **kwargs):
        pass
