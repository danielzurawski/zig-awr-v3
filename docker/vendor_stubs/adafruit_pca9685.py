class _Channel:
    def __init__(self):
        self.duty_cycle = 0


class PCA9685:
    def __init__(self, *args, **kwargs):
        self.frequency = 50
        self.channels = [_Channel() for _ in range(16)]
