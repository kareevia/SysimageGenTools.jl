export begin_tracecompile,  compile_sysimage,  
	sync_manifest_to_sysimage_versions


function filename(base::String, ext::String)
	basfilnam = joinpath(base, Dates.format(Dates.now(), "yymmdd-HHMMSS-sss"))
	filnam = "$basfilnam$ext"

	# check if file with such name already exists and change it 
	if ispath(filnam)
		i = 2
		while ispath((filnam = "$basfilnam-$i$ext"))
			i += 1
		end
	end

	return filnam
end

mutable struct DumpingState
	filename
	io
end


function finalizedumping(ds)
	if ds.filename !== ""
		ccall(:jl_dump_compiles, Nothing, (Ptr{Nothing},), C_NULL)
		close(ds.io)
		mv(ds.filename, ds.filename[begin:end-3] * "raw")
	end
	return
end


const dumpingstate = DumpingState("", nothing)



"""
    begin_tracecompile(; kwargs...)
\n Begin to dump the compiled specializations (*tracecompile* analog).
### Keyword arguments
- `storeto`::String = `joinpath(dirname(Base.active_project()::String), 
  "tracecompile-logs"))` --- the directory to put the dumps to. 
"""
function begin_tracecompile(; storeto::String = joinpath(dirname(
		Base.active_project()::String), "tracecompile-logs"))
	global dumpingstate

	mkpath(storeto)
	filnam = filename(storeto, ".rec")

	# system call to start the dump
	io = open(filnam, "w")
	finalizedumping(dumpingstate)
	ccall(:jl_dump_compiles, Nothing, (Ptr{Nothing},), io.handle)

	dumpingstate.filename = filnam
	dumpingstate.io = io
	
	return filnam
end


function prepare_precomp_statements(logsdir::String)
	staset = Set{String}()
	filto_rem = String[]
		
	# gather from all .raw and .sta files
	for fn in readdir(logsdir; join= true, sort= false)
		if endswith(fn, ".raw")
			for l in eachline(fn)
				mo = match(r"^[^\t]+\t\"(.*)\"[^\"]*$", l)
				if mo !== nothing
					push!(staset, mo[1])
				end
			end
			push!(filto_rem, fn)
		elseif endswith(fn, ".rec")
			for l in eachline(fn)
				mo = match(r"^[^\t]+\t\"(.*)\"[^\"]*$", l)
				if mo !== nothing
					push!(staset, mo[1])
				end
			end
		elseif endswith(fn, ".sta")
			for l in eachline(fn)
				push!(staset, strip(l))
			end
			push!(filto_rem, fn)
		end
	end
	
	# remove prev. recording and save the consolidated results
	foreach(rm, filto_rem)
	filnam  = filename(logsdir, ".sta")
	open(filnam, "w") do io
		for x in sort!(collect(staset))
			write(io, x)
			write(io, "\n")
		end
	end

	return filnam
end

"""
    compile_sysimage(sysimage_path::String = "sysimage.so"; kwargs...)
\n Generate sysimage with inclusion of all packages from the Manifest and 
precompiling functions from tracecompiles from `tracecompile_logs_dir`, cached
methodinstances, and/or concrete methods from the packages

### Keyword arguments
- `tracecompile_logs_dir`::Union{Nothing, String} = nothing --- the directory with the tracecompile logs.
- `packagecompiler_opts`::NamedTuple = `(;)` --- keyword arguments to the 
  underlying `PackageCompiler.create_sysimage` call.
- `only_from_registry`::Bool = `true` --- filter-out packages which aren't from
  the registry.
- `add_packages`::Vector{Symbol} = `Symbol[]` --- additional packages to add. 
  Has no particular user right now since all the packages of the project are 
  added by default
- `remove_packages`::Vector{Symbol} = `Symbol[]` --- the packages to be 
  filtered-out.
- `precomp_predef_specs`::Bool = `true` --- precompile all method 
  specializations found in the packages.
- `precomp_with_concrete_types`::Bool = `true` --- precompile all methods which
  has concrete argument types.
- `eval_before` --- expression to be evaluated in the precompile script before
  all operations.
- `eval_after` --- expression to be evaluated in the precompile script after
all operations.
"""
function compile_sysimage(sysimage_path::String = "sysimage.so"; 
		tracecompile_logs_dir::Union{Nothing, String} = nothing, 
		packagecompiler_opts::NamedTuple = (;),
		only_from_registry::Bool = true,
		add_packages::Vector{Symbol} = Symbol[],
		remove_packages::Vector{Symbol} = Symbol[],
		precomp_predef_specs::Bool = true,
		precomp_concrete_types::Bool = true,
		eval_before::Expr = :(),
		eval_after::Expr = :())
	@nospecialize packagecompiler_opts
	@assert tracecompile_logs_dir === nothing || isdir(tracecompile_logs_dir)

	uid = "a81f1154-5098-11ed-3061-cddc41fb66d8"
	
	if tracecompile_logs_dir !== nothing
		ENV["$uid#statements_file"] = 	
			prepare_precomp_statements(tracecompile_logs_dir)
	else
		ENV["$uid#statements_file"] = ""
	end
	ENV["$uid#add_packages"] = "[$(join(add_packages, ","))]"
	ENV["$uid#remove_packages"] = "[$(join(remove_packages, ","))]"
	ENV["$uid#only_from_registry"] = only_from_registry
	ENV["$uid#precomp_predef_specs"] = precomp_predef_specs
	ENV["$uid#precomp_concrete_types"] = precomp_concrete_types
	ENV["$uid#eval_before"] = repr(eval_before)
	ENV["$uid#eval_after"] = repr(eval_after)


	precomscrpat = joinpath(@__DIR__, "precompile_script.jl")
	PackageCompiler.create_sysimage(String[]; sysimage_path, 
		script= precomscrpat, packagecompiler_opts...)
end


"""
    sync_manifest_to_sysimage_versions()
\n Syncronize versions of packages of the currently active project to the 
sysimage versions
"""
function sync_manifest_to_sysimage_versions()
	to_be_cha = @NamedTuple{name::String, uuid::Base.UUID, 
		version::VersionNumber}[]

	for x in Pkg.dependencies()
		pkgid = Base.PkgId(x[1], x[2].name)
		if Base.in_sysimage(pkgid) && (local po = get( Base.pkgorigins, pkgid, 
				nothing )) !== nothing && po.version !== nothing
			push!(to_be_cha, (; pkgid.name, pkgid.uuid, po.version))
		end
	end	

	if !isempty(to_be_cha)
		manfilnam = joinpath(dirname(Base.active_project()::String), 
			"Manifest.toml")

		if isfile(manfilnam)
			tomdic = TOML.parsefile(manfilnam)

			somhascha = false

			for chapak in to_be_cha
				try
					local d = tomdic["deps"][chapak.name][1]
					if Base.UUID(d["uuid"]) == chapak.uuid && 
							d["version"] != string(chapak.version)

						println("Changed version of \"$(chapak.name)\" from \
							$(d["version"]) to $(chapak.version).")

						d["version"] = string(chapak.version)
						somhascha = true
					end
				catch e
					println("While evaluated \"$(chapak.name)\", got exception: ", e)
				end
			end

			if somhascha
				open(manfilnam, "w") do io 
					TOML.print(io, tomdic)
				end
				Pkg.resolve()
			end
		end
	end
end

#=
function sync_manifest_to_sysimage_versions()
	to_be_fix = Pkg.PackageSpec[]

	for x in Pkg.dependencies()
		pkgid = Base.PkgId(x[1], x[2].name)
		if Base.in_sysimage(pkgid)
			push!(to_be_fix, Pkg.PackageSpec(pkgid.name, pkgid.uuid))
		end
	end	

	if !isempty(to_be_fix)
		#Pkg.update(Pkg.Types.Context(), to_be_upd; level=Pkg.UPLEVEL_FIXED, mode=Pkg.PKGMODE_MANIFEST, update_registry=false, skip_writing_project =true)
		Pkg.update(to_be_fix; level= Pkg.UPLEVEL_FIXED, update_registry=false, 
			skip_writing_project =true)
	end
end
=#