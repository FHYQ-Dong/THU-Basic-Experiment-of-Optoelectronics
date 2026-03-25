import numpy as np

data_in_dBm = np.array([
    -19.23,
    -18.95,
    -17.93,
    -16.41,
    -14.30,
    -13.23,
    -12.09,
    -11.29,
    -10.30
])
data_in_mW = 10 ** (data_in_dBm / 10)
data_in_uW = data_in_mW * 1000
for uW in data_in_uW:
    print(f"{uW:.2f}")