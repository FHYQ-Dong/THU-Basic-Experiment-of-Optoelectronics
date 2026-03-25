import numpy as np
from matplotlib import pyplot as plt

I = np.array([
    0.2 , 2.0 , 4.0 , 6.0 , 8.0 , 8.2 ,
    8.4 , 8.6 , 8.8 , 9.0 , 9.2 , 9.4 ,
    9.6 , 9.8 , 10.0, 12.0, 14.0, 16.0,
    18.0, 20.0, 22.0, 24.0, 25.0, 
])
P = np.array([
    0.04375, 0.5766 , 2.106  , 5.480  , 11.45  , 11.94  ,
    12.74  , 16.11  , 22.86  , 37.15  , 47.53  , 61.80  ,
    74.30  , 93.33  , 104.8  , 250.0  , 391.8  , 538.8  ,
    680.6  , 827.5  , 977.1  , 1124   , 1191   ,
])

# 拟合 8.8 之后的数据为一条直线，在局部放大图中用橙色虚线画出，并标出 x 轴交点
# 选取 I > 8.8 的数据进行线性拟合
mask = I > 8.8
I_fit = I[mask]
P_fit = P[mask]
coeffs = np.polyfit(I_fit, P_fit, 1)  # coeffs[0]: slope, coeffs[1]: intercept

# 计算直线在局部放大图范围内的取值
I_line = np.linspace(7, 11, 100)
P_line = coeffs[0] * I_line + coeffs[1]
dP_dI = coeffs[0]  # 斜率即为 dP/dI

# 计算 x 轴交点
if coeffs[0] != 0:
    x_intercept = -coeffs[1] / coeffs[0]
else:
    x_intercept = np.nan

fig, ax = plt.subplots(figsize=(8, 6))

# 绘制主图
ax.plot(I, P, 'o-')
ax.set_xlabel('$I_d~(mA)$')
ax.set_ylabel('$P_{out}~(uW)$')
ax.set_title('P-I Curve')
ax.grid()

# 创建局部放大图的坐标系 
# 参数为 [x0, y0, width, height]，范围是 0 到 1，相对于主图坐标系的大小和位置
axins = ax.inset_axes([0.15, 0.45, 0.45, 0.45])

# 在局部放大图内绘制数据
axins.plot(I, P, 'o-')
# 在局部放大图中画出拟合直线和 x 轴交点
axins.plot(I_line, P_line, linestyle='--', color='orange', label=f'$P = {coeffs[0]:.2f}I {coeffs[1]:.2f}$')
axins.legend(loc='upper left', fontsize='small')
axins.axvline(x_intercept, color='orange', linestyle=':', ymax=0.15)
axins.annotate(f'{x_intercept:.2f}', xy=(x_intercept, 0), xytext=(x_intercept, -40),
               arrowprops=dict(arrowstyle='->', color='orange'), color='orange')

# 设置局部放大图的 X 轴和 Y 轴显示范围 (对应原 detail 数据的范围)
axins.set_xlim(7, 11)
axins.set_ylim(0, 200)

# 添加网格线以增强局部细节的可读性（可选）
axins.grid(True, linestyle='--', alpha=0.6)

# 绘制将主图特定区域连接到放大图的参考线
indicator = ax.indicate_inset_zoom(axins, edgecolor="gray")
connectors = indicator.connectors
connectors[0].set_visible(True) # 左下角
connectors[1].set_visible(False)  # 左上角
connectors[2].set_visible(True)  # 右下角
connectors[3].set_visible(False) # 右上角

plt.show()