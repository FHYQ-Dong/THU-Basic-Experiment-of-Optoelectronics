import math as m

h = 6.62607015e-34  # Planck constant
c = 299792458  # Speed of light in vacuum
lambda_ = 632.8e-9  # Wavelength of the light in meters

T = 100e-6  # Time interval in seconds

E = h * c / lambda_  # Energy of a photon
P = E / T  # Power in watts

target_P = P
now_P = 225e-6  # 225 uW
adjustment_factor = target_P / now_P
adjustment_factor_dB = 10 * m.log10(adjustment_factor)

print(f"Energy of a photon: {E} J")
print(f"Power: {P} W")
print(f"Adjustment factor (dB): {adjustment_factor_dB} dB")