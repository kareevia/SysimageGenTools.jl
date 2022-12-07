let e = Meta.parse(ENV["a81f1154-5098-11ed-3061-cddc41fb66d8#eval_before"])
	println("\nEvaling `eval_before` expression.")
	Main.eval(e)
end

let mod = Module()
	@eval mod begin
		import Pkg 

		# read options from `compile_sysimage`
		uid = "a81f1154-5098-11ed-3061-cddc41fb66d8"
		const stafil = ENV["$uid#statements_file"]
		const addpac = Meta.parse(ENV["$uid#add_packages"]).args
		const rempac = Meta.parse(ENV["$uid#remove_packages"]).args .|> string |>Set
		const onlfroreg = Meta.parse(ENV["$uid#only_from_registry"])
		const precompredefspe = Meta.parse(ENV["$uid#precomp_predef_specs"])
		const precomcontyp = Meta.parse(ENV["$uid#precomp_concrete_types"])

		const stalis = stafil != "" ? readlines(stafil) : String[]
		
		# gather PkgIDs
		const paklis = [
				Base.PkgId(k, v.name)
				for (k,v) in Pkg.dependencies()
				if v.name ∉ rempac && 
					!onlfroreg || v.is_tracking_registry
			]

		println("\nHave $(length(paklis)) packages and $(length(stalis)) of \
			precompilation statements. Importing the packages...")

		# load the modules
		for p in paklis
			try
				@eval const $(Expr(:$, :(Symbol(p.name)))) = 
					Base.require($(Expr(:$,:p)))
			catch e
				println(stderr, "Exception occured while imported $p.")
				rethrow()
			end
		end

		if !isempty(addpac)
			println("\nImporting additional $(length(addpac)) explicitly added \
				packages")
			for p in addpac
				@eval import $(Expr(:$, :p))
			end
		end
		
		println("\nEvaling precompilation statements.")

		# precompile the specTypes
		const couprecom = Ref(0)
		for (i,l) in enumerate(stalis)
			try
				eval($mod, Meta.parse("precompile("*l*")"))
				couprecom[] = couprecom[] + 1
			catch;  end
		end

		println("\nEvaled $(couprecom[]) of $(length(stalis)) statements.")

		# precompile specializations which are cached in the packages during 
		# precompilation
		if precompredefspe || precomcontyp
			const MethodAnalysis = Base.require(Base.PkgId(
				Base.UUID("85b6ec6f-f7df-4429-9514-a64bcd9ee824"), "MethodAnalysis" ))
		end

		# precompile methodinstances found in the packages
		if precompredefspe
			println("\nGathering list of methodsinstances, cached in the packages.")

			mi = MethodAnalysis.methodinstances()

			println("\nPrecompiling cached methodinstances, got $(length(mi)) \
				specializations.")

			couprecom[] = 0
			for x in mi
				try
					precompile(x.specTypes)
					couprecom[] += 1
				catch;  end				
			end
			
			println("\nEvaled $(couprecom[]) of $(length(mi)) statements.")
			
		end

		# precompile methods with concrete types
		if precomcontyp
			println("\nGathering list of methods with concrete types.")

			local metlis = Method[]
			const cnt = Ref(0)
			MethodAnalysis.visit() do x
				println(cnt[] += 1)
				if x isa Method && isconcretetype(x.sig)
					push!(metlis, x)
					return false
				end
				return true
			end

			println("\nPrecompiling methods with concrete types, got \
				$(length(metlis)) such methods.")

			couprecom[] = 0
			for x in metlis
				try
					precompile(x.sig)
					couprecom[] += 1
				catch;  end				
			end
			
			println("\nEvaled $(couprecom[]) of $(length(metlis)) statements.")

		end
	end
end

let e = Meta.parse(ENV["a81f1154-5098-11ed-3061-cddc41fb66d8#eval_after"])
	println("\nEvaling `eval_after` expression.")
	Main.eval(e)
end
