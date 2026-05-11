# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "matplotlib", "scipy"]
# ///

import os
import sys
import numpy as np
# Use non-interactive backend when running headless (e.g., CI)
if os.environ.get('MPLBACKEND') or not sys.stdout.isatty():
    import matplotlib
    matplotlib.use('Agg')
from matplotlib import pyplot as plt
from scipy.optimize import curve_fit

V = np.array([
    0  , 33 , 62 , 92 , 127, 154, 181, 211, 239, 270,
    305, 330, 363, 398, 406, 419, 425, 436, 440, 444,
    455, 478, 503,
])
I = np.array([
    3.280 , 3.010 , 5.666 , 11.02 , 20.57 , 30.00 , 40.83 , 53.56 ,
    66.96 , 80.16 , 97.76 , 107.3 , 118.0 , 126.1 , 129.6 , 129.0 ,
    131.9 , 132.6 , 133.9 , 132.6 , 129.3 , 127.0 , 122.3 ,
])

# 拟合 I = A*(1 - cos(pi*V/V_pi)) + C
def model(V, A, V_pi, C):
    return A * (1 - np.cos(np.pi * V / V_pi)) + C

# 初始猜测：A ~ (max-min)/2, V_pi ~ V at peak, C ~ min
p0 = [65, 440, 3]
popt, pcov = curve_fit(model, V, I, p0=p0)
A_fit, V_pi_fit, C_fit = popt

print(f'拟合参数: A = {A_fit:.3f}, V_pi = {V_pi_fit:.1f} V, C = {C_fit:.3f}')

V_smooth = np.linspace(0, 520, 500)
I_smooth = model(V_smooth, *popt)

fig, ax = plt.subplots(figsize=(8, 6))

# 主图
ax.plot(V, I, 'o-', markersize=4, label='Measured data')
ax.plot(V_smooth, I_smooth, '--', color='orange', label=f'Fit: $V_\\pi = {V_pi_fit:.1f}$ V')
ax.axvline(V_pi_fit, color='red', linestyle=':', alpha=0.7, label=f'$V_\\pi = {V_pi_fit:.1f}$ V')
ax.set_xlabel('$V~(\\mathrm{V})$')
ax.set_ylabel('$I~(\\mu\\mathrm{W})$')
ax.set_title('I-V Curve (Electro-optic Modulation)')
ax.legend(loc='lower right', fontsize='small')
ax.grid()

# 局部放大图：峰值区域
axins = ax.inset_axes([0.12, 0.50, 0.40, 0.40])
axins.plot(V, I, 'o-', markersize=3)
axins.plot(V_smooth, I_smooth, '--', color='orange')
axins.axvline(V_pi_fit, color='red', linestyle=':', alpha=0.7)
axins.annotate(f'$V_\\pi = {V_pi_fit:.1f}$ V', xy=(V_pi_fit, model(V_pi_fit, *popt)),
               xytext=(V_pi_fit - 80, model(V_pi_fit, *popt) - 15),
               arrowprops=dict(arrowstyle='->', color='red'), color='red', fontsize=9)
axins.set_xlim(350, 520)
axins.set_ylim(115, 140)
axins.grid(True, linestyle='--', alpha=0.6)

indicator = ax.indicate_inset_zoom(axins, edgecolor="gray")
connectors = indicator.connectors
connectors[0].set_visible(True)
connectors[1].set_visible(False)
connectors[2].set_visible(True)
connectors[3].set_visible(False)

connectors[0].set_visible(False) # 左下角
connectors[1].set_visible(False)  # 左上角
connectors[2].set_visible(True)  # 右下角
connectors[3].set_visible(True) # 右上角

plt.savefig('../images/I-V-curve.png', dpi=200, bbox_inches='tight')
plt.show()
