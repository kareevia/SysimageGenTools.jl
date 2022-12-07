module SysimageGenTools

import Dates,  Pkg,  PackageCompiler,  TOML

include("__main.jl")

function __init__()
	global dumpingstate
	finalizer(finalizedumping, dumpingstate)
end

end # module SysimageGenTools
