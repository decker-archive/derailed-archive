import os
import threading
import time

__all__ = "snowflake"


BUCKET_SIZE = 1000 * 60 * 60 * 24 * 7
DERAILED_EPOCH = 1649325271415
INCR = 0


def make_snowflake() -> int:
    current_ms = int(time.time() * 1000)

    epoch = current_ms - DERAILED_EPOCH << 22

    epoch |= (threading.current_thread().ident % 32) << 17
    epoch |= (os.getpid() % 32) << 12

    global INCR

    epoch |= INCR % 4096

    INCR += 1

    return epoch


def make_bucket(snowflake: int) -> int:
    if snowflake is None:
        timestamp = int(time.time() * 1000) - DERAILED_EPOCH
    else:
        timestamp = snowflake >> 22
    return int(timestamp / BUCKET_SIZE)


def make_buckets(start_id: int, end_id: int = None) -> range:
    return range(make_bucket(start_id), make_bucket(end_id) + 1)