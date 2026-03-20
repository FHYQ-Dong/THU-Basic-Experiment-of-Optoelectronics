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

try:
    while True:
        # q = input()
        # if q.lower() == 'q':
        #     ser.write(b'q')
        #     ser.close()
        #     break
        # 生成 uint8: 0, 1, 2, 3 中的一个随机数
        random_number = random.randint(0, 3)
        # print(f"POLOR: {POLAR_MAPPING[random_number]}")
        # 将随机数转换为字节并发送到串口
        ser.write(random_number.to_bytes(1, byteorder='big'))
        # 接收 32-bit 整数 (big-endian)
        # received_data = ser.read(4)
        # if len(received_data) == 4:
        #     received_number = int.from_bytes(received_data, byteorder='big')
        #     # print(f"SYNC: {received_number}")
        # else:
        #     # print("SYNC: ERROR")
        loop_cnt += 1
except KeyboardInterrupt:
    end_time = time.time()
    ser.write(b'q')
    ser.close()
    elapsed_time = end_time - start_time
    print(f"Total loops: {loop_cnt}, Elapsed time: {elapsed_time:.2f} seconds, Speed: {loop_cnt / elapsed_time:.2f} lps")
