import numpy as np
from matplotlib import pyplot as plt

T = np.array([
    14.0, 
    15.0, 
    16.0, 
    17.0, 
    18.0, 
    19.0, 
    20.0, 
    21.0, 
    22.0, 
    23.0, 
    23.9, 
    25.0
])
P = np.array([
    105.7, 
    92.14, 
    77.86, 
    64.11, 
    48.53, 
    34.78, 
    22.06, 
    15.05, 
    13.49, 
    12.45, 
    11.93, 
    11.16
])

plt.plot(T, P, 'o-')
plt.xlabel('T (°C)')
plt.ylabel('$P_{out}$ (uW)')
plt.title('P-T Curve')
plt.grid()
plt.show()
