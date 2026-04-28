"""Stub for vendor Server/RobotLight.py — keeps the Adeept_SPI_LedPixel surface used by WebServer.py."""


class Adeept_SPI_LedPixel:
    def __init__(self, *args, **kwargs):
        pass

    def check_spi_state(self):
        # Vendor logic skips startup if check_spi_state() == 0; that's
        # exactly what we want in the container — no SPI device exists.
        return 0

    def start(self):
        pass

    def breath(self, *args, **kwargs):
        pass

    def police(self, *args, **kwargs):
        pass

    def rainbow(self, *args, **kwargs):
        pass

    def set_all_led_color_data(self, *args, **kwargs):
        pass

    def show(self):
        pass

    def led_close(self):
        pass

    def pause(self):
        pass

    def resume(self):
        pass
