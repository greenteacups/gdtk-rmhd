local sin = math.sin
local cos = math.cos
local exp = math.exp
local pi = math.pi

function refSoln(t, x, y, z)
   tab = {}
   

tab.rho = 0.1*sin(2.3561944901923449*x) + 0.15*cos(3.1415926535897932*y) + 0.08*cos(3.9269908169872415*x*y) +1.0



tab.p = 20000.0*sin(3.9269908169872415*y) - 25000.0*sin(2.3561944901923449*x*y) - 30000.0*cos(3.1415926535897932*x) + 100000.0



tab['T'] = 0.00348432055749129*(20000.0*sin(3.9269908169872415*y)- 25000.0*sin(2.3561944901923449*x*y) - 30000.0*cos(3.1415926535897932*x) + 100000.0)/(0.1*sin(2.3561944901923449*x) + 0.15*cos(3.1415926535897932*y) +0.08*cos(3.9269908169872415*x*y) + 1.0)



tab['vel.x'] = 4.0*sin(5.235987755982989*x) - 12.0*cos(4.7123889803846899*y) + 7.0*cos(1.8849555921538759*x*y) +70.0



tab['vel.y'] = 4.0*sin(3.1415926535897932*y) - 20.0*cos(4.7123889803846899*x) - 11.0*cos(2.827433388230814*x*y) +90.0



   return tab
end

refSolidSoln = refSoln

