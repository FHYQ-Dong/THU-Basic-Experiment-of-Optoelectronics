import os
os.chdir(os.path.dirname(os.path.abspath(__file__)))

with open(r'data/FT1080_S12345678_T2_64ps_20260507_163143_033_s0.txt', 'r') as f:
    lines = f.readlines()
    lines = lines[12:]
    lines = [line.split() for line in lines]
    cnt = 0
    for line in lines:
        if line[1] == '4':
            cnt += 1
    print(cnt)