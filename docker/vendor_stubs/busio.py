class I2C:
    def __init__(self, *args, **kwargs):
        pass

    def try_lock(self):
        return True

    def unlock(self):
        pass

    def writeto(self, *args, **kwargs):
        pass

    def readfrom_into(self, *args, **kwargs):
        pass


class SPI:
    def __init__(self, *args, **kwargs):
        pass

    def configure(self, *args, **kwargs):
        pass
