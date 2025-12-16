# *****************************************************************
# * Copyright (C) 2024  gNext Labs LLC - All Rights Reserved
# *
# * Unauthorized copying of this code, via any medium is strictly prohibited
# * Proprietary and confidential
# * Written by Abraham Lama Salomon <abraham.lama@gnextlabs.com>, 2021
# ******************************************************************

""" Main module used to format and give color to the logs on the console.

    Requires python 3.1 and was inspired from "https://stackoverflow.com/questions/384076/how-can-i-color-python-logging-output"

    Typical usage example:

        # create logger with 'spam_application'
        logger = logging.getLogger("My_app")
        logger.setLevel(logging.DEBUG)

        # create console handler with a higher log level
        ch = logging.StreamHandler()
        ch.setLevel(logging.DEBUG)

        ch.setFormatter(CustomFormatter())

        logger.addHandler(ch)
"""

import logging

class CustomFormatter(logging.Formatter):
    """Logging Formatter to add colors and count warning / errors"""

    #format = "%(asctime)s - %(name)s - %(levelname)s - %(message)s (%(filename)s:%(lineno)d)"

    format = "___%(asctime)s, %(levelname)s: %(message)s (%(filename)s:%(lineno)d)"


    # here if where we choose the format for each log type.
    FORMATS = {
        logging.DEBUG: format,
        logging.INFO: format,
        logging.WARNING: format,
        logging.ERROR: format,
        logging.CRITICAL: format,
    }

    # method that applies the format to each log
    def format(self, record):
        log_fmt = self.FORMATS.get(record.levelno)
        formatter = logging.Formatter(log_fmt)
        return formatter.format(record)