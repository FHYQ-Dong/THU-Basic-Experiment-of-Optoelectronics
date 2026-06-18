import random
import serial
import time
import winsound

ser = serial.Serial(
    port="COM8",
    baudrate=250000
)

POLAR_MAPPING = {
    0: '00',
    1: '90',
    2: '45',
    3: '135'
}


loop_cnt = 0
random_str = ''
run_time = 1800
total_numbers = 250000 / 10 * run_time

print(f"Generating {total_numbers} random numbers in {run_time} seconds...")
random_numbers = [random.randint(0, 3) for _ in range(int(total_numbers))]
# random_numbers = [1 for _ in range(int(total_numbers))]
random_numbers_hex = b''.join([random_number.to_bytes(1, byteorder='big') for random_number in random_numbers])

start_time = time.time()
ser.write(random_numbers_hex)
end_time = time.time()
ser.write(b'q')
ser.close()

datafile = open("random_data_1800s_250kHz.txt", "w")
datafile.write('\n'.join(str(num) for num in random_numbers))
datafile.close()

elapsed_time = end_time - start_time
print(f"Total loops: {loop_cnt}, Elapsed time: {elapsed_time:.2f} seconds, Speed: {total_numbers / elapsed_time:.2f} lps")

for _ in range(3):
    winsound.Beep(1000, 300)
    time.sleep(0.1)

# 0x00: 407.5 -> 225.2
# 0x01: 453.2 -> 225.9
# 0x02: 225.0 -> ok
# 0x03: 565.0 -> 225.1

# 63.6 + 45.5

# 0 -> CH1 -> 0
# 1 -> CH4 -> 3
# 2 -> CH3 -> 2
# 3 -> CH2 -> 1