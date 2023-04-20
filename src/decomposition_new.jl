
# merge all entries of dictionary used for capacity data into one dataframe for the specified columns
mergeVar(var_dic::Dict{Symbol,Dict{Symbol,Dict{Symbol,DataFrame}}},outCol::Array{Symbol,1}) = vcat(vcat(vcat(map(x -> var_dic[x] |> (u -> map(y -> u[y] |> (w -> map(z -> w[z][!,outCol],collect(keys(w)))),collect(keys(u)))),[:tech,:exc])...)...)...)

# structure managing stabilization method
mutable struct stabObj
	method::Array{Symbol,1} # array of method names used for stabilization
	methodOpt::Array{NamedTuple,1} # array of options for adjustment of stabilization parameters
	ruleSw::Union{NamedTuple{(), Tuple{}}, NamedTuple{(:itr, :avgImp, :itrAvg), Tuple{Int64, Float64, Int64}}} # rule for switching between stabilization methods
	actMet::Int # index of currently active stabilization method
	objVal::Float64 # array of objective value for current center
	dynPar::Array{Float64,1} # array of dynamic parameters for each method
	var::Dict{Symbol,Dict{Symbol,Dict{Symbol,DataFrame}}} # variables subject to stabilization
	cns::ConstraintRef
	function stabObj(meth_dic::Dict, ruleSw_ntup::NamedTuple, objVal_fl::Float64,lowBd_fl::Float64,relVar_dic::Dict{Symbol,Dict{Symbol,Dict{Symbol,DataFrame}}},top_m::anyModel)
		stab_obj = new()
		
		# set fields for name and options of method
		meth_arr = Symbol[]
		methOpt_arr = NamedTuple[]
		for (key,val) in meth_dic
			push!(meth_arr,key)
			push!(methOpt_arr,val)
			if key == :qtr && !isempty(setdiff(keys(val),(:start,:low,:thr,:fac)))
				error("options provided for trust-region do not match the defined options 'start', 'low', 'thr', and 'fac'")
			elseif key == :prx && !isempty(setdiff(keys(val),(:start,:low,:ov,:fac)))
				error("options provided for proximal bundle do not match the defined options 'start', 'low', 'thr', and 'fac'")
			elseif key == :lvl && !isempty(setdiff(keys(val),(:la,)))
				error("options provided for level bundle do not match the defined options 'la'")
			end
		end
		
		if !(isempty(ruleSw_ntup) || typeof(ruleSw_ntup) == NamedTuple{(:itr,:avgImp,:itrAvg),Tuple{Int64,Float64,Int64}})
			error("rule for switching stabilization method must be empty or have the fields 'itr', 'avgImp', and 'itrAvg'")
		end

		stab_obj.method = meth_arr
		stab_obj.methodOpt = methOpt_arr

		# method specific adjustments (e.g. starting value for dynamic parameter, new variables for objective function)
		dynPar_arr = Float64[]
		for m in 1:size(meth_arr,1)
			if meth_arr[m] == :prx
				dynPar = objVal_fl * methOpt_arr[m].start # starting value for penalty
			elseif meth_arr[m] == :lvl
				dynPar = (methOpt_arr[m].la * lowBd_fl  + (1 - methOpt_arr[m].la) * objVal_fl) / top_m.options.scaFac.obj # starting value for level
			elseif meth_arr[m] == :qtr
				dynPar = methOpt_arr[m].start # starting value for radius
			else
				error("unknown stabilization method provided, method must either be 'prx', 'lvl', or 'qtr'")
			end
			push!(dynPar_arr,dynPar)
		end
		stab_obj.dynPar = dynPar_arr
		
		# set other fields
		stab_obj.ruleSw = ruleSw_ntup
		stab_obj.actMet = 1
		stab_obj.objVal = objVal_fl
		stab_obj.var = filterStabVar(relVar_dic,top_m)
		
		# compute number of variables subject to stabilization
		stabExpr_arr = vcat(vcat(vcat(map(x -> stab_obj.var[x] |> (u -> map(y -> u[y] |> (w -> map(z -> w[z][!,:value],collect(keys(w)))),collect(keys(u)))),[:tech,:exc])...)...)...)

		return stab_obj, size(stabExpr_arr,1)
	end
end

# filter variables used for stabilization
function filterStabVar(allVal_dic::Dict{Symbol,Dict{Symbol,Dict{Symbol,DataFrame}}},top_m::anyModel)

	var_dic = Dict(x => Dict{Symbol,Dict{Symbol,DataFrame}}() for x in [:tech,:exc])

	for sys in (:exc,:tech)
		part_dic = getfield(top_m.parts,sys)
		for sSym in keys(allVal_dic[sys])
			var_dic[sys][sSym] = Dict{Symbol,Dict{Symbol,DataFrame}}() # create empty dataframe for values
			
			# determine where using expansion rather than capacity is possible and more efficient
			varNum_dic = Dict(x => size(unique(getfield.(part_dic[sSym].var[x][!,:var],:terms)),1) for x in collect(keys(part_dic[sSym].var))) # number of unique variables
			trstVar_arr = map(filter(x -> occursin("capa",string(x)),collect(keys(part_dic[sSym].var)))) do x
				expVar_sym = Symbol(replace(string(x),"capa" => "exp"))
				return part_dic[sSym].decomm == :none && expVar_sym in keys(varNum_dic) && varNum_dic[expVar_sym] <= varNum_dic[x] ? expVar_sym : x
			end

			for trstSym in intersect(keys(allVal_dic[sys][sSym]),trstVar_arr)
				var_df = allVal_dic[sys][sSym][trstSym]
				if trstSym == :capaExc && !part_dic[sSym].dir filter!(x -> x.R_from < x.R_to,var_df) end # only get relevant capacity variables of exchange
				if sys == :tech var_df = removeFixStorage(trstSym,var_df,part_dic[sSym]) end # remove storage variables controlled by ratio
				# filter cases where acutal variables are defined
				var_dic[sys][sSym][trstSym] = intCol(var_df) |> (w ->innerjoin(var_df,unique(select(filter(x -> !isempty(x.var.terms), part_dic[sSym].var[trstSym]),w)), on = w))
				# remove if no capacities remain
				removeEmptyDic!(var_dic[sys][sSym],trstSym)
			end
			
			# remove entire system if not capacities
			removeEmptyDic!(var_dic[sys],sSym)
		end
	end
	return var_dic
end

# function to update the center of stabilization method
centerStab!(method::Symbol,stab_obj::stabObj,top_m::anyModel) = centerStab!(Val{method}(),stab_obj::stabObj,top_m::anyModel)

# function for quadratic trust region
function centerStab!(method::Val{:qtr},stab_obj::stabObj,top_m::anyModel)

	# match values with variables in model
	expExpr_dic = matchValWithVar(stab_obj.var,top_m)
	allVar_df = vcat(vcat(vcat(map(x -> expExpr_dic[x] |> (u -> map(y -> u[y] |> (w -> map(z -> w[z][!,[:var,:value]],collect(keys(w)))),collect(keys(u)))),[:tech,:exc])...)...)...)
	
	# sets values of variables that will violate range to zero
	minFac_fl = (2*maximum(allVar_df[!,:value]))/(top_m.options.coefRng.mat[2] / top_m.options.coefRng.mat[1])
	allVar_df[!,:value] = map(x -> 2*x.value < minFac_fl ? 0.0 : x.value,eachrow(allVar_df))

	# compute possible range of scaling factors with rhs still in range
	abs_fl = sum(allVar_df[!,:value]) |> (x -> x < 0.01 * size(allVar_df,1) ? 10 * size(allVar_df,1) : x)
	scaRng_tup = top_m.options.coefRng.rhs ./ abs((abs_fl * stab_obj.dynPar[stab_obj.actMet])^2 - sum(allVar_df[!,:value].^2))

	# get scaled l2-norm expression for capacities
	capaSum_expr, scaFac_fl = computeL2Norm(allVar_df,stab_obj,scaRng_tup,top_m)

	# create final constraint
	stab_obj.cns = @constraint(top_m.optModel,  capaSum_expr * scaFac_fl <= (abs_fl * stab_obj.dynPar[stab_obj.actMet])^2  * scaFac_fl)
	
end

# function for proximal bundle method
function centerStab!(method::Val{:prx},stab_obj::stabObj,top_m::anyModel)
	
	# match values with variables in model
	expExpr_dic = matchValWithVar(stab_obj.var,top_m)
	allVar_df = vcat(vcat(vcat(map(x -> expExpr_dic[x] |> (u -> map(y -> u[y] |> (w -> map(z -> w[z][!,[:var,:value]],collect(keys(w)))),collect(keys(u)))),[:tech,:exc])...)...)...)

	pen_fl = stab_obj.dynPar[stab_obj.actMet]
	
	# sets values of variables that will violate range to zero
	minFac_fl = (2*pen_fl*maximum(allVar_df[!,:value]))/(top_m.options.coefRng.mat[2] / top_m.options.coefRng.mat[1])
	allVar_df[!,:value] = map(x -> 2*pen_fl*x.value < minFac_fl ? 0.0 : x.value,eachrow(allVar_df))

	# compute possible range of scaling factors with rhs still in range
	scaRng_tup = top_m.options.coefRng.rhs ./ sum(allVar_df[!,:value].^2)

	# get scaled l2-norm expression for capacities
	capaSum_expr, scaFac_fl = computeL2Norm(allVar_df,stab_obj,scaRng_tup,top_m)

	# adjust objective function
	@objective(top_m.optModel, Min, top_m.parts.obj.var[:obj][1,1] + pen_fl * capaSum_expr  * scaFac_fl)

end

# function for level bundle method
function centerStab!(method::Val{:lvl},stab_obj::stabObj,top_m::anyModel)
	
	# match values with variables in model
	expExpr_dic = matchValWithVar(stab_obj.var,top_m)
	allVar_df = vcat(vcat(vcat(map(x -> expExpr_dic[x] |> (u -> map(y -> u[y] |> (w -> map(z -> w[z][!,[:var,:value]],collect(keys(w)))),collect(keys(u)))),[:tech,:exc])...)...)...)
	
	# sets values of variables that will violate range to zero
	minFac_fl = (maximum(allVar_df[!,:value]))/(top_m.options.coefRng.mat[2] / top_m.options.coefRng.mat[1])
	allVar_df[!,:value] = map(x -> x.value < minFac_fl ? 0.0 : x.value,eachrow(allVar_df))

	# compute possible range of scaling factors with rhs still in range
	scaRng_tup = top_m.options.coefRng.rhs ./ sum(allVar_df[!,:value].^2)

	# get scaled l2-norm expression for capacities
	capaSum_expr, scaFac_fl = computeL2Norm(allVar_df,stab_obj,scaRng_tup,top_m)

	# adjust objective function and level set
	@objective(top_m.optModel, Min, 0.5 * capaSum_expr  * scaFac_fl)
	set_upper_bound(top_m.parts.obj.var[:obj][1,1],stab_obj.dynPar[stab_obj.actMet])
end

# ! solves top problem without trust region and obtains lower limits
function runTopWithoutStab(top_m::anyModel,stab_obj::stabObj)
	
	if stab_obj.method[stab_obj.actMet] == :qtr
		delete(top_m.optModel,stab_obj.cns) # remove trust-region
	elseif stab_obj.method[stab_obj.actMet] == :prx
		@objective(top_m.optModel, Min, top_m.parts.obj.var[:obj][1,1]) # remove penalty form objective
	elseif stab_obj.method[stab_obj.actMet] == :lvl
		@objective(top_m.optModel, Min, top_m.parts.obj.var[:obj][1,1])
		delete_upper_bound(top_m.parts.obj.var[:obj][1,1])
	end
	
	set_optimizer_attribute(top_m.optModel, "Method", 0)
	set_optimizer_attribute(top_m.optModel, "NumericFocus", 0)
	optimize!(top_m.optModel)

	# obtain different objective values
	objTop_fl = value(sum(filter(x -> x.name == :cost, top_m.parts.obj.var[:objVar])[!,:var])) # costs of unconstrained top-problem
	lowLim_fl = objTop_fl + value(filter(x -> x.name == :benders,top_m.parts.obj.var[:objVar])[1,:var]) # objective (incl. benders) of unconstrained top-problem

	return objTop_fl, lowLim_fl
end

# ! matches values in dictionary with variables of provided problem
function matchValWithVar(capa_dic::Dict{Symbol,Dict{Symbol,Dict{Symbol,DataFrame}}},mod_m::anyModel)
	# ! match values with variables
	expExpr_dic = Dict{Symbol,Dict{Symbol,Dict{Symbol,DataFrame}}}()
	for sys in (:tech,:exc)
		expExpr_dic[sys] = Dict{Symbol,Dict{Symbol,DataFrame}}()
		part_dic = getfield(mod_m.parts,sys)
		for sSym in keys(capa_dic[sys])
			expExpr_dic[sys][sSym] = Dict{Symbol,DataFrame}()
			for varSym in keys(capa_dic[sys][sSym])
				val_df = deSelectSys(capa_dic[sys][sSym][varSym])
				# correct scaling and storage values together with corresponding variables
				val_df[!,:value] = val_df[!,:value] ./ getfield(mod_m.options.scaFac, occursin("exp",string(varSym)) ? :insCapa : (occursin("StSize",string(varSym)) ? :capaStSize : :capa))
				expExpr_dic[sys][sSym][varSym] = unique(select(innerjoin(deSelectSys(part_dic[sSym].var[varSym]),val_df, on = intCol(val_df,:dir)),[:var,:value]))
			end
		end
	end

	return expExpr_dic
end

# ! compute scaled l2 norm
function computeL2Norm(allVar_df::DataFrame,stab_obj::stabObj,scaRng_tup::Tuple,top_m::anyModel)

	# set values of variable to zero or biggest value possible without scaling violating rhs range
	for x in eachrow(allVar_df)	
		if top_m.options.coefRng.mat[1]/(x.value*2) > scaRng_tup[2] # factor requires more up-scaling than possible
			x[:value] = 0 # set value to zero
		elseif top_m.options.coefRng.mat[2]/(x.value*2) < scaRng_tup[1] # factor requires more down-scaling than possible
			x[:value] = top_m.options.coefRng.mat[2]/(scaRng_tup[1]*2) # set to biggest value possible within range
		end
	end

	# computes left hand side expression and scaling factor
	capaSum_expr = sum(map(x -> collect(keys(x.var.terms))[1] |> (z -> z^2 - 2*x.value*z + x.value^2),eachrow(allVar_df)))
	scaFac_fl =  top_m.options.coefRng.mat[1]/minimum(abs.(collect(values(capaSum_expr.aff.terms)) |> (z -> isempty(z) ? [1.0] : z)))

	return capaSum_expr, scaFac_fl

end
