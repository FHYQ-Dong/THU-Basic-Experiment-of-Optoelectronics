import random
import serial
import time

ser = serial.Serial(
    port="COM8",
    baudrate=115200
)

POLAR_MAPPING = {
    0: '00',
    1: '90',
    2: '45',
    3: '135'
}

start_time = time.time()
loop_cnt = 0

datafile = open("random_data_10s.txt", "w")

try:
    while True:
        random_number = random.randint(0, 3)
        # random_number = 0x02
        ser.write(random_number.to_bytes(1, byteorder='big'))
        datafile.write(f"{random_number} ")
        loop_cnt += 1
except KeyboardInterrupt:
    end_time = time.time()
    ser.write(b'q')
    ser.close()
    datafile.close()
    elapsed_time = end_time - start_time
    print(f"Total loops: {loop_cnt}, Elapsed time: {elapsed_time:.2f} seconds, Speed: {loop_cnt / elapsed_time:.2f} lps")

# 0x00: 407.5 -> 225.2
# 0x01: 453.2 -> 225.9
# 0x02: 225.0 -> ok
# 0x03: 565.0 -> 225.1

# 63.6 + 45.5

# 0 -> CH1 -> 0
# 1 -> CH4 -> 3
# 2 -> CH3 -> 2
# 3 -> CH2 -> 1