### A Pluto.jl notebook ###
# v0.19.41

#> [frontmatter]
#> title = "Conformal Model for Energy Forecasting and Trading Optimization"
#> date = "2024-05-08"
#> tags = ["Flux", "Conformal Models", "Conditional Value at Risk", "Julia", "Pluto", "Metal", "GPU Programming", "Machine Learning", "Time-Series Forecasting"]
#> description = "Semester project for Rutgers Energy Markets and Data Analytics, Spring 2024. We applied conformal modeling to a GRU to predict energy production data and trading prices for the IEEE Hybrid Energy Competition. We then applied Conditional Value at Risk to optimize the trading strategy."
#> 
#>     [[frontmatter.author]]
#>     name = "Daniel Moore"
#>     [[frontmatter.author]]
#>     name = "Laila Saleh"

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
end

# ╔═╡ d1856c6d-302c-4f13-9a3d-1c143fc0585d
begin
	using PlutoUI
	using CSV, DataFrames, Dates
	using Flux
	using StatsBase, StatsPlots
	gr(fontfamily=:Times)
	md"""
	# Loading Packages
	"""
end

# ╔═╡ 1431c33d-00cd-40be-a548-c473cf2be82c
TableOfContents(depth=2)

# ╔═╡ 4694df35-d2d8-4d39-ba60-07a894357d09
TableOfContents(aside=false, depth=3)

# ╔═╡ 7773febb-95f8-4c44-8eda-98397a3b7ad0
md"""
Missing:
- forecasted demand
- forecasted weather

Historical data is not available for these, but we know they are critical to predicting both the generation and demand. Further, we expect there is a complex dynamic with the prices. We have opted to include historical data to fill in this gap. Day-ahead weather forecasts are accurate enough that the difference is not expected to change the model parameters or performance drastically.
"""

# ╔═╡ 44f9d85c-3218-4c54-8308-d873119ed64a
md"""
# 1. Loading Data
"""

# ╔═╡ caf44cc1-e597-43c9-9db9-a34afca02a50
md"""
## 1.1 Data from RebaseAPI
"""

# ╔═╡ b4381993-9840-4379-b124-428477ce474c
md"""
Data was pulled using the RebaseAPI and team key in a different file. It was combined on like keys to conveniently be loaded here.
"""

# ╔═╡ 5067d15f-2af0-4e45-83af-44f1adc840d4
begin
	data = CSV.read("data_rebase.csv", DataFrame)
	filter!(row -> !any(ismissing, row), data)
	select!(data, Not(:solar_pred, :wind_offshore_pred, :wind_onshore_pred))
	data[!, Not(:timestamp_utc)] = Float32.(data[!, Not(:timestamp_utc)])
	rename!(data, :solar_act=>:Solar, :wind_act=>:Wind, :dayahead_price=>:DAP, :imbalance_price=>:SSP)
	data.TotalEnergy = data.Wind + data.Solar
	select!(data, :timestamp_utc, :Solar, :Wind, :TotalEnergy, :DAP, :SSP)
	energy_cols = names(data)[2:end]
	data
end

# ╔═╡ c8c89920-2466-4cf0-927a-d1fe927ecb1b
md"""
## 1.2 Weather Data
"""

# ╔═╡ 40e49425-d5f1-4bf1-8a89-233cd26c0ad2
begin
	weather = CSV.read("hornsea 2024-02-29 to 2024-04-06.csv", DataFrame)
	weather_cols = ["temp", "windspeed", "winddir", "cloudcover"]
	select!(weather, ["datetime"; weather_cols])
	weather[!, Not(:datetime)] = Float32.(weather[!, Not(:datetime)])
	select!(weather, :datetime, :temp, :windspeed, :winddir, :cloudcover)
end

# ╔═╡ 4d6fe02c-78b7-45a0-b8da-1c6cd9712b84
md"""
## 1.3 Combining Data Sources
"""

# ╔═╡ 5d901945-77b9-4298-ae4c-7f89f3b5d87f
begin
	data.temp_time = floor.(data.timestamp_utc, Dates.Hour(1))
	sort!(leftjoin!(data, weather, on=:temp_time=>:datetime), :timestamp_utc)
	select!(data, Not(:temp_time))
	filter!(row -> !any(ismissing, row), data)
	unique!(data)
	select!(data, ["timestamp_utc"; weather_cols; energy_cols])
	data[!, 2:end] = data[:, 2:end] .|> Float32
	data
end

# ╔═╡ b1178733-e724-4622-9cd7-3c3c4a58d44a
md"""
# 2. Data Visualizations
"""

# ╔═╡ 1dc18c4d-5dbe-460d-ac84-28e1ac6dbab5
function every4hrs_date_noon(dt)
	if hour(dt) % 4 == 0 & minute(dt) == 0
		if hour(dt) == 12
			Dates.format(dt, "u-d HH:MM")
		else
			Dates.format(dt, "HH:MM")
		end
	end
end

# ╔═╡ 2940b832-970b-4538-ab11-e2a3836226f2
begin
	monthly_ticks =(
		DateTime(Date(data.timestamp_utc[findfirst(d -> dayofweek(d)==Sun, data.timestamp_utc)]), Time(12)):Week(1):last(data.timestamp_utc),
		
		Dates.format.(
			DateTime(Date(data.timestamp_utc[findfirst(d -> dayofweek(d)==Sun, data.timestamp_utc)]), Time(12)):Week(1):last(data.timestamp_utc),
			"u-d"
		)
	)

	daily_xticks = (Time(0):Hour(3):Time(23), Dates.format.(Time(0):Hour(3):Time(23), "HH:MM"))
	
	cmap = Dict(
		"DAP" => :darkgreen,
		"SSP" => :orange,
		"temp" => :darkred,
		"Solar" => :gold,
		"Wind" => :darkblue,
		"CloudCover" => :darkgrey,
		"Total Energy" => :hotpink,
	)
	
	clouds = cgrad([:gold, :darkgrey])
	winds = cgrad([:white, :blue])
	temp =cgrad(:turbo)
	md"Some plotting conviences"
end

# ╔═╡ ba88b58c-da54-42be-960b-d9f364b3cc30
md"""
## 2.1 Time-Series Plots
"""

# ╔═╡ c52230e8-68db-44cf-9116-88fd650ee9de
@df data plot(
	xticks = monthly_ticks,
	:timestamp_utc,
	[:DAP :SSP],
	color=[cmap["DAP"] cmap["SSP"]],
	α=[0.5 0.5],
	lw=[2 1.5]
)

# ╔═╡ b8d205f1-671c-4b78-acf3-fa90f8ae9998
@df last(data, 7*24*2) plot(
	:timestamp_utc,
	[:DAP :SSP],
	color=[cmap["DAP"] cmap["SSP"]],
	α=[0.5 0.5],
	lw=[2 1.5]
)

# ╔═╡ 839b72dc-d0e3-41bf-abb0-4e930f9c48fe
@df data plot(
	xticks=monthly_ticks,
	xlabel="Day", ylabel="Energy Generation",
	:timestamp_utc,
	[:Solar :Wind],
	color=[cmap["Solar"] cmap["Wind"]],
	α=[0.5 0.5],
	lw=[3 1.5]
)

# ╔═╡ e35e969e-5aa3-4026-8335-6bf1dc2f8961
@df last(data, 7*24*2) plot(
	xlabel="Day", ylabel="Energy Generation",
	:timestamp_utc,
	[:Solar :Wind],
	color=[cmap["Solar"] cmap["Wind"]],
	α=[0.5 0.5],
	lw=[4 1.5]
)

# ╔═╡ df3d803a-4d52-41ef-82ae-2655217cb1b8
md"""
## 2.2 Time-Series & Temperature Plots
"""

# ╔═╡ 013d8a03-aa87-45f9-bf39-4703a9ad56a1
# ╠═╡ show_logs = false
@df data plot(
	layout=@layout([a b{.1w}]),

	plot(
		cbar=false, xrotation=45,
		
		plot(
			ylabel="DAP",
			xaxis=false, xticks=monthly_ticks,
			:timestamp_utc, :DAP, label=false,
			line_z = :temp, color=:turbo, α=0.3, lw=3)
		
		, plot(
			xaxis=false, xticks=daily_xticks,
			Time.(:timestamp_utc), :DAP, label=false,
			group=yearmonthday.(:timestamp_utc),
			line_z = :temp, color=temp, α=0.3, lw=3)

		, plot(
			ylabel="SSP",
			xticks=monthly_ticks,
			:timestamp_utc, :SSP, label=false,
			line_z = :temp, color=:turbo, α=0.3, lw=3)
		
		, plot(
			xticks=daily_xticks,
			Time.(:timestamp_utc), :SSP, label=false,
			group=yearmonthday.(:timestamp_utc),
			line_z = :temp, color=temp, α=0.3, lw=3)
	),
	plot(
		xlims=(0,0),
		[-2, -2],
		[extrema(:temp)[1], extrema(:temp)[2]], label=false,
		line_z = [extrema(:temp)[1], extrema(:temp)[2]],
		color=temp, cbartitle="°C", framestyle=:none)
)

# ╔═╡ 5d34fd78-ddad-4d38-9ac3-71c68e85480f
# ╠═╡ show_logs = false
@df data plot(
	layout=@layout([a b{0.1w}]),
	plot(layout=(2,1), cbar=false,
	
		plot(
			ylabel="Solar Production", xticks=false,
			Time.(:timestamp_utc), :Solar, label=false,
			group=yearmonthday.(:timestamp_utc),
			line_z = :cloudcover, color=clouds, α=0.5, lw=5,
		),
	
		scatter(
			xlabel="Time of Day", ylabel="Solar Production", xticks=daily_xticks,
			Time.(:timestamp_utc), :Solar, label=false,
			group=yearmonthday.(:timestamp_utc),
			mz = :cloudcover, color=clouds, α=0.3, ms=10, markerstrokewidth=0.0,
		)
	),

	plot(
		xlims=(0,0),
		[-2, -2],
		[extrema(:cloudcover)[1], extrema(:cloudcover)[2]], label=false,
		line_z = [extrema(:cloudcover)[1], extrema(:cloudcover)[2]],
		color=clouds, cbartitle="Cloud Cover (%)", framestyle=:none)
		
)

# ╔═╡ 87992e42-ed6a-478c-b468-a6017f2083c9
# ╠═╡ show_logs = false
@df data plot(
	layout=@layout([a b{0.1w}]),
	plot(layout=(2,1), cbar=false,
	
		plot(
			ylabel="Solar Production", xticks=false,
			Time.(:timestamp_utc), :Solar, label=false,
			group=yearmonthday.(:timestamp_utc),
			line_z = :temp, color=temp, α=0.5, lw=5,
		),
	
		scatter(
			xlabel="Time of Day", ylabel="Solar Production", xticks=daily_xticks,
			Time.(:timestamp_utc), :Solar, label=false,
			group=yearmonthday.(:timestamp_utc),
			mz = :temp, color=temp, α=0.3, ms=10, markerstrokewidth=0.0,
		)
	),

	plot(
		xlims=(0,0),
		[-2, -2],
		[extrema(:temp)[1], extrema(:temp)[2]], label=false,
		line_z = [extrema(:temp)[1], extrema(:temp)[2]],
		color=temp, cbartitle="° C)", framestyle=:none)
)

# ╔═╡ 8555d123-e074-4242-9138-75e63983b9d3
# ╠═╡ show_logs = false
@df data plot(
	layout=@layout([a b{0.1w}]),
	plot(
		layout=(2,1), cbar=false,
		plot(
			ylabel="Wind Production", xticks=false,
			Time.(:timestamp_utc), :Wind, label=false,
			group=yearmonthday.(:timestamp_utc), lz = :windspeed, color=winds, lw=4, α=0.5),
	
		scatter(
			xlabel="Time of Day", ylabel="Wind Production",
			xticks=daily_xticks,
			Time.(:timestamp_utc), :Wind, label=false,
			group=yearmonthday.(:timestamp_utc), mz = :windspeed, color=winds, ms=10, markerstrokewidth=0.3, α=0.5)
	),
	
	plot(
		xlims=(0,0),
		[-2, -2],
		[extrema(:windspeed)[1], extrema(:windspeed)[2]], label=false,
		line_z = [extrema(:windspeed)[1], extrema(:windspeed)[2]],
		color=winds, cbartitle="Wind Speed (kph)", framestyle=:none)
)

# ╔═╡ c8a64528-2a86-4806-8949-949e0e12c5ff
# ╠═╡ show_logs = false
@df data plot(
	layout=@layout([a b{0.1w}]),
	plot(
		layout=(2,1), cbar=false,
		plot(
			ylabel="Wind Production", xticks=false,
			Time.(:timestamp_utc), :Wind, label=false,
			group=yearmonthday.(:timestamp_utc), lz = :temp, color=temp, lw=4, α=0.5),
	
		scatter(
			xlabel="Time of Day", ylabel="Wind Production",
			xticks=daily_xticks,
			Time.(:timestamp_utc), :Wind, label=false,
			group=yearmonthday.(:timestamp_utc), mz = :temp, color=temp, ms=10, markerstrokewidth=0.3, α=0.5)
	),
	
	plot(
		xlims=(0,0),
		[-2, -2],
		[extrema(:temp)[1], extrema(:temp)[2]], label=false,
		line_z = [extrema(:temp)[1], extrema(:temp)[2]],
		color=temp, cbartitle="° C", framestyle=:none)
)

# ╔═╡ d513b0d2-8719-4328-86af-75d2b5bdc829
# ╠═╡ show_logs = false
@df data plot(
	layout=@layout([a b{0.1w}]),
	plot(
		layout=(2,1), cbar=false,
		plot(
			ylabel="Total Energy", xticks=false,
			Time.(:timestamp_utc), :TotalEnergy, label=false,
			group=yearmonthday.(:timestamp_utc), lz = :temp, color=temp, lw=4, α=0.5),
	
		scatter(
			xlabel="Time of Day", ylabel="Total Energy",
			xticks=daily_xticks,
			Time.(:timestamp_utc), :TotalEnergy, label=false,
			group=yearmonthday.(:timestamp_utc), mz = :temp, color=temp, ms=10, markerstrokewidth=0.3, α=0.5)
	),
	
	plot(
		xlims=(0,0),
		[-2, -2],
		[extrema(:temp)[1], extrema(:temp)[2]], label=false,
		line_z = [extrema(:temp)[1], extrema(:temp)[2]],
		color=temp, cbartitle="° C", framestyle=:none)
)

# ╔═╡ 2a9b7009-3ac7-4431-8806-af081d5435c2
# ╠═╡ show_logs = false
@df data plot(
	layout=@layout([a b{0.1w}]),
	plot(
		layout=(2,1), cbar=false,
		plot(
			ylabel="Total Energy", xticks=false,
			Time.(:timestamp_utc), :TotalEnergy, label=false,
			group=yearmonthday.(:timestamp_utc), lz = :windspeed, color=winds, lw=4, α=0.5),
	
		scatter(
			xlabel="Total Energy", ylabel="Wind Production",
			xticks=daily_xticks,
			Time.(:timestamp_utc), :TotalEnergy, label=false,
			group=yearmonthday.(:timestamp_utc), mz = :windspeed, color=winds, ms=10, markerstrokewidth=0.3, α=0.5)
	),
	
	plot(
		xlims=(0,0),
		[-2, -2],
		[extrema(:windspeed)[1], extrema(:windspeed)[2]], label=false,
		line_z = [extrema(:windspeed)[1], extrema(:windspeed)[2]],
		color=winds, cbartitle="Wind Speed (kph)", framestyle=:none)
)

# ╔═╡ 83f8334c-494a-412b-989e-0d7caf412d58
md"""
## 2.3 Statistical Plots
"""

# ╔═╡ e84757f5-eeed-4409-badc-899a2583a6bc
@df data plot(
	legend=false,
	histogram(title="DAP", :DAP, color=cmap["DAP"]),
	histogram(title="SSP", :SSP, color=cmap["SSP"])
)

# ╔═╡ a863584b-3611-4130-b162-7966859fb891
@df data begin
	plot(title="Empirical CDF", xlabel="Price")
	ecdfplot!(:DAP, color=cmap["DAP"], label="DAP")
	ecdfplot!(:SSP, color=cmap["SSP"], label="SSP")
end

# ╔═╡ 772072d2-fc85-4ce5-8c10-294512978b81
@df data marginalkde(:DAP, :SSP, xlabel="DAP", ylabel="SSP")

# ╔═╡ da3f2a32-653e-4ea0-8e14-f3731ba1b056
@df data marginalkde(:TotalEnergy, :DAP, xlabel="Total Energy", ylabel="DAP")

# ╔═╡ 79e81287-54af-4083-9de0-e82515ef7be3
@df data marginalkde(:TotalEnergy, :SSP, xlabel="Total Energy", ylabel="SSP")

# ╔═╡ ee0b93ce-1baf-4b71-a23a-81c9279a4f8f
plot(
	layout=(2,1), ylabel="Price", legend=false, #xticks = (1:7, dayabbr.(1:7)),
	begin
		@df data violin(
			title="DAP",
			Date.(:timestamp_utc), :DAP, label="DAP",
			color=cmap["DAP"], α=0.5
		)

		@df data boxplot!(
			title="DAP",
			Date.(:timestamp_utc), :DAP, label="DAP",
			color=:black, α=0.25
		)
	end
	,
	begin
		@df data violin(
			title="SSP",
			Date.(:timestamp_utc), :SSP, label="SSP",
			color=cmap["SSP"], α=0.5
		)
		@df data boxplot!(
			title="SSP",
			Date.(:timestamp_utc), :SSP, label="SSP",
			color=:black, α=0.25
		)
	end
)

# ╔═╡ 470213e1-dc5e-4d32-acce-dff405aba7c2
plot(
	layout=(2,1), ylabel="Price", legend=false, xticks = (1:7, dayabbr.(1:7)),
	begin
		@df data violin(
			title="DAP",
			dayofweek.(:timestamp_utc), :DAP, label="DAP",
			color=cmap["DAP"], α=0.5
		)

		@df data boxplot!(
			title="DAP",
			dayofweek.(:timestamp_utc), :DAP, label="DAP",
			color=:black, α=0.25
		)
	end
	,
	begin
		@df data violin(
			title="SSP",
			dayofweek.(:timestamp_utc), :SSP, label="SSP",
			color=cmap["SSP"], α=0.5
		)
		@df data boxplot!(
			title="SSP",
			dayofweek.(:timestamp_utc), :SSP, label="SSP",
			color=:black, α=0.25
		)
	end
)

# ╔═╡ 9aca9018-e6cc-48a6-adae-53d09cdb0339
plot(
	layout=(2,1), ylabel="Price", legend=false, xticks=(0:4:23, "$h:00" for h ∈ 0:4:23),
	begin
		@df data violin(
			title="DAP",
			hour.(:timestamp_utc), :DAP, label="DAP",
			color=cmap["DAP"], α=0.5
		)

		@df data boxplot!(
			title="DAP",
			hour.(:timestamp_utc), :DAP, label="DAP",
			color=:black, α=0.25
		)
	end
	,
	begin
		@df data violin(
			title="SSP",
			hour.(:timestamp_utc), :SSP, label="SSP",
			color=cmap["SSP"], α=0.5
		)
		@df data boxplot!(
			title="SSP",
			hour.(:timestamp_utc), :SSP, label="SSP",
			color=:black, α=0.25
		)
	end
)

# ╔═╡ 1806279a-0f67-4658-b5c9-1eebc6ed7919
plot(
	layout=(3,1), size=(800,900),
	ylabel="Energy", legend=false, #xticks = (1:7, dayabbr.(1:7)),
	begin
		@df data violin(
			title="Solar",
			Date.(:timestamp_utc), :Solar, label="Solar",
			color=cmap["Solar"], α=0.5
		)

		@df data boxplot!(
			Date.(:timestamp_utc), :Solar, label="Solar",
			color=:black, α=0.25
		)
	end
	,
	begin
		@df data violin(
			title="Wind",
			Date.(:timestamp_utc), :Wind, label="Wind",
			color=cmap["Wind"], α=0.5
		)
		@df data boxplot!(
			Date.(:timestamp_utc), :Wind, label="Wind",
			color=:black, α=0.25
		)
	end
	,
	begin
		@df data violin(
			title="Total Energy",
			Date.(:timestamp_utc), :TotalEnergy, label="TotalEnergy",
			color=cmap["Total Energy"], α=0.5
		)
		@df data boxplot!(
			Date.(:timestamp_utc), :TotalEnergy, label="TotalEnergy",
			color=:black, α=0.25
		)
	end
)

# ╔═╡ 5f2308de-a8c6-4c36-9bb8-40da9f393bf7
plot(
	layout=(3,1), size=(800, 900),
	ylabel="Energy", legend=false, xticks = (1:7, dayabbr.(1:7)),
	begin
		@df data violin(
			title="Solar",
			dayofweek.(:timestamp_utc), :Solar, label="Solar",
			color=cmap["Solar"], α=0.5
		)

		@df data boxplot!(
			dayofweek.(:timestamp_utc), :Solar, label="Solar",
			color=:black, α=0.25
		)
	end
	,
	begin
		@df data violin(
			title="Wind",
			dayofweek.(:timestamp_utc), :Wind, label="Wind",
			color=cmap["Wind"], α=0.5
		)
		@df data boxplot!(
			dayofweek.(:timestamp_utc), :Wind, label="Wind",
			color=:black, α=0.25
		)
	end
		,
	begin
		@df data violin(
			title="Total Energy",
			dayofweek.(:timestamp_utc), :TotalEnergy, label="Total Energy",
			color=cmap["Total Energy"], α=0.5
		)
		@df data boxplot!(
			dayofweek.(:timestamp_utc), :TotalEnergy, label="Total Energy",
			color=:black, α=0.25
		)
	end

)

# ╔═╡ 88622208-488a-419f-95d5-641f2a71d7e5
plot(
	layout=(3,1),
	size=(800,900),
	ylabel="Energy",
	legend=false,
	xticks=(0:4:23, "$h:00" for h ∈ 0:4:23),
	begin
		@df data violin(
			title="Solar",
			hour.(:timestamp_utc), :Solar, label="Solar",
			color=cmap["Solar"], α=0.5
		)

		@df data boxplot!(
			hour.(:timestamp_utc), :Solar, label="Solar",
			color=:black, α=0.25
		)
	end
	,
	begin
		@df data violin(
			title="Wind",
			hour.(:timestamp_utc), :Wind, label="Wind",
			color=cmap["Wind"], α=0.5
		)
		@df data boxplot!(
			hour.(:timestamp_utc), :Wind, label="Wind",
			color=:black, α=0.25
		)
	end
	,
	begin
		@df data violin(
			title="Total Energy",
			hour.(:timestamp_utc), :TotalEnergy, label="Total Energy",
			color=cmap["Total Energy"], α=0.5
		)
		@df data boxplot!(
			hour.(:timestamp_utc), :TotalEnergy, label="Total Energy",
			color=:black, α=0.25
		)
	end
)

# ╔═╡ 35b76c76-9749-4070-ba4f-aafa10349250
begin
	plot(title="Energy Production Empirical CDF")
	@df data ecdfplot!(:Wind, label="Wind", color=cmap["Wind"])
	@df data ecdfplot!(:Solar, label="Solar", color=cmap["Solar"])
	@df data ecdfplot!(:TotalEnergy, label="Total Energy", color=cmap["Total Energy"])
end

# ╔═╡ 6cf2abfd-0652-4b0b-8d64-5896c058dc49
@df data marginalkde(:Solar, :Wind, xlabel="Solar", ylabel="Wind")

# ╔═╡ d503570f-efff-4642-ab19-12a88699bc4a
@df data corrplot(
	size=(2500,2500),
	[hour.(:timestamp_utc) + minute.(:timestamp_utc) / 60 :Solar :Wind :DAP :SSP :temp :windspeed :winddir :cloudcover],
	label=["Time" "Solar" "Wind" "DAP" "SSP" "temp" "windspeed" "winddir" "cloudcover"],
	grid=false, bins=50
)

# ╔═╡ 79337a1e-f774-42b9-9ce4-5f78b8dacd6c
md"""
# 3. Data Transformation
"""

# ╔═╡ 1f2ef155-c827-400f-8f34-9ead965a4831
md"""
The data must be standardized because the current measurements are all on a different scale and we plan to use a multi-output recurrent network. If we had a different model for each variable, it may not be necessary but we would either lose information about the relationships amongst the data or make an overly complicated workflow.

Below, we store the transform information to a `Dict` accessed by the column name so that we can easily reconstruct predictions which were made on the transformed data.
"""

# ╔═╡ 618271a1-3d80-4eb5-8902-5fdd7b3b648e
transforms = Dict(
    names(data)[i] => StatsBase.fit(UnitRangeTransform, data[:, i])
    for i in 2:size(data, 2)
)

# ╔═╡ 160ebfa2-fd91-4ed9-8f6c-f1069aba5a9d
function to_decimal_hours(timestamp)
    hours = hour(Time(timestamp))
    minutes = minute(Time.(timestamp)) / 60
    return hours + minutes
end

# ╔═╡ fc7a63b1-1ed7-4567-9c08-dfeedb283d3b
function to_cos_time(dt)
	t = Time(dt)
	t = hour(t) + minute(t)/60
	ct = cos(t * 2π/24)+1
	return ct/2 |> Float32
end

# ╔═╡ 6b5b8d8c-fb5a-42a5-bdb3-36829a16d52f
function standardize_df(df, xfrms)
	temp_df = deepcopy(df)
    for (col_name, transform) in xfrms
        if col_name in names(temp_df)
            temp_df[:, col_name] = StatsBase.transform(transform, temp_df[:, col_name])
        end
    end

	temp_df.timestamp_utc = to_cos_time.(temp_df.timestamp_utc)

	rename!(temp_df, :timestamp_utc=>:cos_time)
	
    return temp_df
end

# ╔═╡ 6070b6c9-4f91-4acb-ba65-880bcf4237b1
function reconstruct_df(df, xfrms)
	temp_df = deepcopy(df)
    for (col_name, transform) in xfrms
        if col_name in names(temp_df)
            temp_df[:, col_name] = StatsBase.reconstruct(transform, temp_df[:, col_name])
        end
    end
    return temp_df
end

# ╔═╡ 6f987b3d-5726-41eb-8bd5-7a70f31e7af5
md"""
We will be using `Flux` to create and train the model. Below we transform the data into the format expected by Flux. In its current state, the data is a DataFrame where each row is an observation at a given time with observations in 30-minute intervals. Each column is represents a feature of the observation.

Flux requires the timesteps to be a Vector where each element corresponds to an observation and each element is a Matrix with rows representing the features and columns representing the samples. See below for a simplified example. We are going to create three samples out of this by shortening the sequence from 6 to 4. This will allow us to create rolling-squences.

Origional Data

| Time | Wind | DAP |
| ---- | ---- | --- |
| 1    | W1   | D1  |
| 2    | W2   | D2  |
| 3    | W3   | D3  |
| 4    | W4   | D4  |
| 5    | W5   | D5  |
| 6    | W6   | D6  |

The columns are rearranged to make it clear that the sequence does not go from left to right, but from top to bottom. The columns could be in any order as long as they are consistent.

```julia
batched_data = [
	[
		W1 W3 W4 W2
		D1 D3 D4 D2
	],
	[
		W2 W4 W5 W3
		D2 D4 D5 D3
	],
	[
		W3 W5 W6 W4
		D3 D5 D6 D4
	],
]
```
"""

# ╔═╡ 9a9adfc7-e4cb-479b-a572-304cc0ad8cb5
md"""
Next we need to consider what we are going to pass to the recurrent network and what we are going to get out of it. We bear in mind:
- Make predicitons for the next 24-hours at 8:00 AM every day
- Assume we have accurate forecasts for the next 24-hours at that time
- Assume we have accurate weather data and energy data for all past times at that time

To accomplish this, we will iteratively make a prediction for energy data one timestep at a time. That prediction will then be combined with the forecasted weather data to make another predition. This will continue until the 24-hour forecast is complete.

This is possible with GRU's (and Recurrent frameworks in general) because they have a cell which "remembers" the past. So we don't have to create a rigid structure for the neural network which requires exactly T number of observations and outputs exactly h number of forecasts.
"""

# ╔═╡ 96c6f674-1a3b-47de-ab23-bd586fb70448
function BatchMaker(
	data;
	weather_cols=weather_cols, energy_cols=energy_cols,
	batch_size=8
)

    xfrm = standardize_df(data, transforms)
	
	# pull the data from the DataFrame to a Matrix
	# it's already been converted to Float32 so there won't be issues
	# then we transpose it so that it is in `features` x `time`
	xfrm = Matrix(xfrm) |> transpose

	#xfrm = [xfrm[:, i] for i in 1:size(xfrm, 2)]
	sequence_of_batches = [xfrm[:, i:i+(batch_size-1)] for i in 1:size(xfrm, 2)-(batch_size-1)]

	past = sequence_of_batches[1:end-1]
	next = [sequence_of_batches[i][end-4:end, :] for i in 2:length(sequence_of_batches)]
	
	return [(past=p, next=n) for (p, n) in zip(past, next)]
end

# ╔═╡ 9eb3bc1c-ea1c-4bec-ad7d-02b8f4ad81f0
begin
	train_test_ratio = 2/5
	calib_ratio = 2/5
	test_ratio = 1-(train_test_ratio+calib_ratio)
	
	train_index = 1:Int(floor(size(data, 1) * train_test_ratio))
	calib_index = last(train_index)+1:last(train_index)+Int(floor(size(data, 1) * calib_ratio))
	test_index = last(calib_index):size(data,1)

	batch_size=2^5
	
	Train = BatchMaker(data[train_index, :],
		batch_size=batch_size
	)
	
	Test = BatchMaker(data[test_index, :],
			batch_size=batch_size
	)

	md"splits"
end

# ╔═╡ b92061c7-71c3-46dd-a5d7-0ec49511016b
md"""
We split the data using the first 3/5 as the training data and latest 2/5 as testing data. The assumption here is that the dynamics are consistent so we don't need to obtain sequences from all over the historic data for training and different sequences for testing. This simplifies data handling and provides more training data because the sequences aren't cut whenever it switches from an observation in the training data to an observation in the testing data and vice-versa.
"""

# ╔═╡ 7960fc2d-3d6e-4060-ac80-6a5fd7723c7e
md"# 4. Forecast Models"

# ╔═╡ 290ba563-2207-49e9-b966-7b3088e17f79
md"""
## 4.1 Benchmark Models
"""

# ╔═╡ 1ec722d8-853a-4394-8faa-3cba23c7db78
md"""
## 4.2 Long Short-term Memory
"""

# ╔═╡ f8ee81c8-ee45-49cb-8f60-4585573b9e9e
md"""
### 4.2.1 Building the Model
"""

# ╔═╡ 2383bb87-2049-4a07-9b71-eba7b726c4d7
md"""
We are using Flux to create a Long/Short-Term Memory network. We send it processed data and it makes predictions for the energy data.
"""

# ╔═╡ f64e1a46-dd78-4e31-a5ea-b6b32fdaea81
md"""
The plot below shows some activation functions for reference.
"""

# ╔═╡ 5216be48-4981-4388-b288-ea2353a165bd
plot(
	title="Activation Functions",
	-3:0.25:3, [x->σ(x), x->tanh(x), x->3tanh(x), x->relu(x)],
	label=["σ" "tanh" "3tanh" "relu"], marker=3
)

# ╔═╡ 3bf6802f-e4a9-4c6d-b5ae-f9750bbe82c4
md"""
### 4.2.2 Setting up the Optimizer
"""

# ╔═╡ 08769354-34f9-4f3e-8b2a-f43278f38269
md"""
### 4.2.3 Loss Function
"""

# ╔═╡ c6d8f4ce-475e-4636-980f-faf07b3ebfd9
md"""
We will use mean-squared error to train the model. As our model is multivariate output, all errors are treated equally so the optimizer will use loss gradients without weight for any particular variable. This is why we normalized the data so it would all be on roughly the same order of magnitude.
"""

# ╔═╡ cf1455b6-05da-4053-ab07-902153dc0958
loss(m, X, Y) = Flux.mse(m(X), Y)

# ╔═╡ 07563188-dbb1-4610-a62c-0fbaf6cf1d4f
loss(m::Chain, traindata::NamedTuple) = loss(m, traindata.past, traindata.next)

# ╔═╡ fcf90c27-ab69-4b90-bada-ce30fd1dbd07
begin
	# this is the number of features in our data
	input_dims = length(weather_cols) + length(energy_cols) + 1

	# this is the number of features we want to output
	output_dim = length(energy_cols)

	hidden_dim = 2^3

	# the model is created by `Chain`ing layers together.
	model = Chain(
		LSTM_in = LSTM(input_dims => hidden_dim),
		LSTM_hidden = LSTM(hidden_dim => hidden_dim),
		Dense_hidden1 = Dense(hidden_dim => hidden_dim),
		Dense_out = Dense(hidden_dim => output_dim, σ),
	)

	Flux.reset!(model)
	train_log = [loss(model, first(Train))]
	Flux.reset!(model)
	test_log = [loss(model, first(Test))]

	model
end	

# ╔═╡ ae194c55-8529-4843-9f64-2dde07f08da8
md"""
### 4.2.4 Creating a `train!` function.
"""

# ╔═╡ 92e26370-e4f1-4b24-b48f-01384cd5a4d0
function train!(opt_state, model, loss, traindata; train_log=[])
	L, ∇ = Flux.withgradient(loss, model, traindata)

	# Detect loss of Inf or NaN. Print a warning, and then skip update!
    if !isfinite(L)
		@warn "Loss value, \"$L\", is invalid."
	else
		Flux.update!(opt_state, model, ∇[1])
    end

	push!(train_log, L)
end

# ╔═╡ 4a84f584-18be-41a2-aab7-186204a09b03
md"""
### 4.2.5 Training and Evaluation
"""

# ╔═╡ 3b0b04c2-e89e-4e87-86f0-5a599ed04646
md"Train epochs: $(
	@bind train_epochs confirm(
		Slider(2 .^ (0:1:12), default=2^5, show_value=true),
		label=\"Send it!\"
	)
)"

# ╔═╡ 52210b74-2957-481f-8f36-7b9bdf68c630
md"Learning Rate, $η$ : $(
	@bind learning_rate confirm(Slider(-8:1:-1, default=-3, show_value=true))
)"

# ╔═╡ d8048221-286d-413b-bb83-c8be118094e4
begin
	η = round(10.0^learning_rate, digits=8)
	opt_state = Flux.setup(Adam(η), model)
end

# ╔═╡ 7498d60f-8134-4b26-9579-1eea8b6667d9
md"Run it? $(@bind run_train_loop CheckBox(false))"

# ╔═╡ 720e6b90-3e85-4c90-9c54-e8ae469a9cba
begin
	if run_train_loop
		for e in 1:train_epochs
			temp_log = []
			Flux.reset!(model)
			model(first(Train).past)

			for T in Train[2:end]
				train!(opt_state, model, loss, T, train_log=temp_log)
			end

			push!(train_log, mean(temp_log))

			Flux.reset!(model)
			model(first(Test).past)
			push!(test_log, mean(loss(model, T) for T in Test[2:end]))
		end
	end

	plot(
		title="Loss Logging",
		xlabel="Total Training Epochs", ylabel="Loss (MSE)",
		[train_log test_log],
		label=["Train" "Test"],
		xticks=2 .^ (0:8),
		xscale=:log2)
end

# ╔═╡ cc545f2b-37b8-4f00-b551-8e41dfe0d532
begin
	Flux.reset!(model)
	[model(T.past) for T in Train[1:end-1]]
	
	train_sample = model(last(Train).past) |> transpose
	
	Flux.reset!(model)
	
	[model(T.past) for T in Test[1:end-1]]
	test_sample = model(last(Test).past) |> transpose
	md"Re-evaluating model on test and train data for plotting"
end

# ╔═╡ 311f71fe-8096-4062-8ded-cfee8dd989b2
md"#### One-step-ahead Predictions"

# ╔═╡ e3d9321e-db98-4d28-8c9d-34aebf3fb6cb
md"##### Train Data"

# ╔═╡ 92b957dc-5244-4766-99b1-7c0ea470bef3
plot(
	layout=@layout((2,1)), legend=:outertopright,
	plot(
		title="True Value",
		last(Train).next |> transpose,
		label=["Solar" "Wind" "Total Energy" "DAP" "SSP"],
		color=[
			cmap["Solar"] cmap["Wind"] cmap["Total Energy"] cmap["DAP"] cmap["SSP"]
		]
		),
	plot(
		title="Predictions",
		train_sample,
		label=["Solar" "Wind" "Total Energy" "DAP" "SSP"],
		color=[
			cmap["Solar"] cmap["Wind"] cmap["Total Energy"] cmap["DAP"] cmap["SSP"]
		]
		),
)

# ╔═╡ c37ec15d-8968-486a-b625-cc337f09c4a5
md"##### Test Data"

# ╔═╡ 58156220-e508-444d-b4c1-34260fd98037
plot(
	layout=@layout((2,1)), legend=:outertopright,
	plot(
		title="True Value",
		last(Test).next |> transpose,
		label=["Solar" "Wind" "Total Energy" "DAP" "SSP"],
		color=[
			cmap["Solar"] cmap["Wind"] cmap["Total Energy"] cmap["DAP"] cmap["SSP"]
		]
		),
	plot(
		title="Predictions",
		test_sample,
		label=["Solar" "Wind" "Total Energy" "DAP" "SSP"],
		color=[
			cmap["Solar"] cmap["Wind"] cmap["Total Energy"] cmap["DAP"] cmap["SSP"]
		]
		),
)

# ╔═╡ 7174cf2c-8cf9-4089-8951-5e52a43fe1e1
md"#### Full day Predictions"

# ╔═╡ da868574-1fc3-494c-b928-bf8c0e0832f7
md"##### Single Day"

# ╔═╡ 9365ff42-21d4-49da-be59-bbd0d8d78ca7
md"Forecast for Day: $(@bind forecast_day confirm(Slider(
	minimum(Date.(data.timestamp_utc))+Day(3):
	maximum(Date.(data.timestamp_utc)), show_value=true, default=Date(2024,4,1)))
)"

# ╔═╡ 080d2217-217e-4366-8275-07036daf777b
md"##### Multiple Day Predictions"

# ╔═╡ b56b7c78-bbb4-4c3c-a49b-4069e809d99f
md"##### Error Plots"

# ╔═╡ be60977b-84f5-4355-92d5-291843dedf8b
md"##### Residual Histogram"

# ╔═╡ 3a3a0a71-ebb8-41e4-8d2f-c68c6daaf772
function forecast(data, firstforecast, lastforecast)
	firstforecast = findlast(row -> row ≤ firstforecast, data.timestamp_utc)
	lastforecast = findlast(row -> row < lastforecast, data.timestamp_utc)
	
	xfrm = standardize_df(data, transforms)
	
	M = xfrm |> Matrix |> transpose

	Flux.reset!(model)

	for i in 1:size(M, firstforecast)-1
		model(M[:, i])
	end

	results = [model(M[:, firstforecast])]
	for j in firstforecast+1:lastforecast
		new_result = model([M[1:5, j];last(results)])
		push!(results, new_result)
	end

	out_df = DataFrame(hcat(results...) |> transpose, energy_cols)
	out_df.timestamp_utc = data[firstforecast:lastforecast, :timestamp_utc]
	select!(out_df, :timestamp_utc, :)
	out_df = reconstruct_df(out_df, transforms)
end

# ╔═╡ 114b88c0-27d6-49a9-ba44-d4f78a5d5611
begin
	firstforecast = DateTime(forecast_day, Time(8, 30))
	lastforecast = firstforecast + Hour(24)
	results = forecast(data, firstforecast, lastforecast)
end

# ╔═╡ 4dd60134-242b-4857-aa69-56c55d0021f4
xticks=range(
	DateTime(Date(firstforecast),Time(8)),
	DateTime(Date(firstforecast), Time(8))+Day(1),
	step=Hour(4)
)

# ╔═╡ 3c23a6f7-78f3-4076-9e02-5a0b48c697cb
begin
	@df filter(
		row -> firstforecast ≤ row.timestamp_utc < lastforecast, data
		) plot(
		legend=:outertopright,
		:timestamp_utc,
		[:Solar, :Wind, :TotalEnergy],
		labels=["Solar" "Wind" "Total Energy"],
		color=[cmap["Solar"] cmap["Wind"] cmap["Total Energy"]],
		line=(1, 0.5)
	)
	
	@df results plot!(
		:timestamp_utc,
		[:Solar, :Wind, :TotalEnergy],
		labels=["Solar (p)" "Wind (p)" "Total Energy (p)"],
		color=[cmap["Solar"] cmap["Wind"] cmap["Total Energy"]],
		line=(2, :dash),
		xticks=(xticks, every4hrs_date_noon.(xticks))
	)
end

# ╔═╡ a47837ac-8de8-42c9-8ea2-a3ef6619db4c
begin
	@df filter(
		row -> firstforecast ≤ row.timestamp_utc < lastforecast, data
		) plot(
		legend=:outertopright,
		:timestamp_utc,
		[:DAP, :SSP],
		labels=["DAP" "SSP"],
		color=[cmap["DAP"] cmap["SSP"]],
		line=(1, 0.5)
	)
	
	@df results plot!(
		:timestamp_utc,
		[:DAP, :SSP],
		labels=[ "DAP (p)" "SSP (p)"],
		color=[cmap["DAP"] cmap["SSP"]],
		line=(2, :dash),
		xticks=(xticks, every4hrs_date_noon.(xticks))
	)
end

# ╔═╡ f88ec603-6a91-4c2e-9ab1-9cb1aeb28ab4
Revenue(Trade, DAP, Actual, SSP) = Trade*DAP + (Actual-Trade) * (SSP - 0.07*(Actual-Trade))

# ╔═╡ fc1bdd7b-3f20-415f-aac2-e1d87c1038f0
begin
	predictions = []
	for d in unique(data.timestamp_utc .|> Date)[2:end]
		push!(predictions, forecast(
				data,
				DateTime(d, Time(8, 30)),
				DateTime(d, Time(8, 30)) + Hour(24))
		)
	end
	predictions = vcat(predictions...)
	p_energy_cols = ["$(col)_pred" for col in energy_cols]
	energy_pairs = energy_cols .=> p_energy_cols
	rename!(predictions, energy_pairs)
	leftjoin!(predictions, data, on=:timestamp_utc)
	predictions.Revenue = Revenue.(
		predictions.TotalEnergy_pred,
		predictions.DAP,
		predictions.TotalEnergy,
		predictions.SSP)
	predictions
end		

# ╔═╡ 3b627bcb-6b24-4caa-93d0-f0ec60d64f33
@df last(predictions, 250) plot(
	layout=@layout((3,1)), size=(800, 600), legend=:outertopright,
	plot(
		title="Total Energy",
		:timestamp_utc, [:TotalEnergy :TotalEnergy_pred],
		color=cmap["Total Energy"], label=["Y" "Ŷ"], line=[:solid :dash]
		
	),
	plot(
		title="Day Ahead Price",
		:timestamp_utc, [:DAP :DAP_pred],
		color=cmap["DAP"], label=["Y" "Ŷ"], line=[:solid :dash]
	),
	plot(
		title="Imbalance Price",
		:timestamp_utc, [:SSP :SSP_pred],
		color=cmap["SSP"], label=["Y" "Ŷ"], line=[:solid :dash]
	),
)

# ╔═╡ c6a5c0c3-b7c7-4987-864b-b69eb48b4f21
@df last(predictions, 250) plot(
	layout=@layout((3,1)), legend=:outertopright,
	plot(
		:timestamp_utc, :TotalEnergy_pred - :TotalEnergy,
		label="ΔTotal Energy", color=cmap["Total Energy"]
	),
	plot(
		:timestamp_utc, :DAP_pred - :DAP,
		label="ΔDAP", color=cmap["DAP"]
	),
	plot(
		:timestamp_utc, :SSP_pred - :SSP,
		label="ΔSSP", color=cmap["SSP"]
	),
)

# ╔═╡ c42de5db-c9b2-4fc0-a8b5-53ce1a818e89
@df last(predictions, 250)	plot(
		title="Coherence of Total prediciton and Solar+Wind prediction",
		:timestamp_utc, [:TotalEnergy_pred :Solar_pred+:Wind_pred :TotalEnergy],
		label=["Total (p)" "Solar+Wind" "True"],
		color=[cmap["Total Energy"] cmap["Wind"] :grey],
		line=[:solid :solid :solid], lw=[2 1 5], lα=[1 1 0.2]
)

# ╔═╡ 7de3d275-eea4-487f-aa38-2462d440c05e
@df predictions scatter(
	title="Surplus/Defecit and Revenue",
	ylabel="ΔTotal Energy {predicted, actual}",
	:timestamp_utc, :TotalEnergy_pred - :TotalEnergy, label=false,
	marker_z=:Revenue/1e3,
	color=cgrad([:red, :yellow, :green], [0, .71, 1]),
	ms=5, markerstrokewidth=0.0, mα=0.6,
	cbartitle="Revenue (thousands \$)"
)

# ╔═╡ 6d0c90fc-b398-4a63-a129-e950ae84169c
@df predictions plot(
	title="Cumulative Earnings",
	:timestamp_utc, cumsum(:Revenue), label=false,
	line_z=:TotalEnergy,
	color=cgrad([:white,:hotpink]), lw=5,
	cbartitle="Total Energy Production"
)

# ╔═╡ 7160f04d-d684-403f-8ede-9de2f5997f99
@df predictions plot(
	layout=@layout((3,1)), legend=false,
	
	histogram(
		title="Total Energy",
		:TotalEnergy_pred - :TotalEnergy,
		color=cmap["Total Energy"]
	),
	histogram(
		title="DAP",
		:DAP_pred - :DAP,
		color=cmap["DAP"]
	),
	histogram(
		title="SSP",
		:SSP_pred - :SSP,
		color=cmap["SSP"]
	)
)

# ╔═╡ de408642-0f01-4832-9e51-37895b3a5ccd
@df predictions histogram(
		title="Revenue", legend=false,
		:Revenue,
		color=:darkgreen
	)

# ╔═╡ 8d1110e2-9940-4171-ade1-7eb3c83b9332
@df predictions ecdfplot(
		title="Revenue", legend=false,
		:Revenue,
		color=:darkgreen
	)

# ╔═╡ f4106179-42f4-4620-895c-cae10d81d8e6
data[calib_index, :]

# ╔═╡ 7707022c-7067-4611-b708-79814fab4564
md"""
# 5. Conformalizing the LSTM Model
"""

# ╔═╡ d45fe2a2-ca99-4af4-b2cd-86c0824a7cd8
md"""
### 5.1 Theory
"""

# ╔═╡ bf15eb86-ab97-417f-b6c1-2da5915bce56
md"""
Now we take the 
"""

# ╔═╡ daed30c6-0d40-4d03-a33d-ff1f89ef9161
begin
	X = [x.past for x in Train]
	y = [y.next for y in Train]
end

# ╔═╡ d75c78d4-f545-4b52-a1d7-5c2ff570b172
builder = MLJFlux.@builder Chain(
	LSTM_in = LSTM(input_dims => hidden_dim),
	LSTM_hidden = LSTM(hidden_dim => hidden_dim),
	Dense_hidden1 = Dense(hidden_dim => hidden_dim),
	Dense_out = Dense(hidden_dim => output_dim, σ),
)

# ╔═╡ a805e6a0-58e0-4c06-8a3b-f9ffaf76bf0b
reg = MultitargetNeuralNetworkRegressor(
    builder=builder,
    epochs=2^5,
    loss=Flux.mse
)

# ╔═╡ 7741430f-d27a-4adf-988c-5805bd69baae
mach = machine(reg, X, y)

# ╔═╡ c01d54bb-c161-46ce-b64e-14a2a7c023d0
models()

# ╔═╡ ccee0fff-b4d7-4594-a2f5-b62318f51588
md"""
# 6. Optimal Trading
"""

# ╔═╡ c47ca169-b110-4691-bdcb-d2c0f13ea64d
md"""
## 6.1 Conditional Value at Risk
All trading will be done with a conditional value at risk which will minimize the operator's risk.
"""

# ╔═╡ ca473b94-f00f-4ca0-a298-d4e8373aca3b
md"""
Here is the function for calcualting revenue for each period according to the competition. Note how the `(Actual-Trade)` serves to reward or punish underestimating or overestimating the production, respectively. Also, the value of SSP relative to the DAP can have significant effects on the total revenue. The $0.07×(Actual-Trade)$ is a competition specific approximation of the effect imbalance has on the price, so the units of this is \$/Power.

|                | SSP < DAP                                             | SSP > DAP |
| :------------- | :---------------------------------------------------- | :-------- |
| Actual < Trade | (+) Benefitted from purchasing shortage at lower SSP  | (-) Forced to buy shortage at higher SSP                  |
| Actual > Trade | (-) Could have sold more at DAP                       | (+) Benefitted from selling excess at higher price |
"""

# ╔═╡ 252fd0dc-e692-4429-903c-fcf7058e3f0b
md"""
# 7. Performance Evaluation
"""

# ╔═╡ 66cdd4d2-9e24-442e-bec0-e2c6c8a226e4
md"""
# 8. Conclusion
"""

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
Dates = "ade2ca70-3891-5945-98fb-dc099432e06a"
Flux = "587475ba-b771-5e3f-ad9e-33799f191a9c"
PlutoUI = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
StatsBase = "2913bbd2-ae8a-5f71-8c99-4fb6c76f3a91"
StatsPlots = "f3b207a7-027a-5e70-b257-86293d7955fd"

[compat]
CSV = "~0.10.13"
DataFrames = "~1.6.1"
Flux = "~0.14.15"
PlutoUI = "~0.7.58"
StatsBase = "~0.33.21"
StatsPlots = "~0.15.7"
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.10.2"
manifest_format = "2.0"
project_hash = "628f8237e5feb06fd7281ae9a6c43fef17931e69"

[[deps.AbstractFFTs]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "d92ad398961a3ed262d8bf04a1a2b8340f915fef"
uuid = "621f4979-c628-5d54-868e-fcf4e3e8185c"
version = "1.5.0"
weakdeps = ["ChainRulesCore", "Test"]

    [deps.AbstractFFTs.extensions]
    AbstractFFTsChainRulesCoreExt = "ChainRulesCore"
    AbstractFFTsTestExt = "Test"

[[deps.AbstractPlutoDingetjes]]
deps = ["Pkg"]
git-tree-sha1 = "0f748c81756f2e5e6854298f11ad8b2dfae6911a"
uuid = "6e696c72-6542-2067-7265-42206c756150"
version = "1.3.0"

[[deps.Adapt]]
deps = ["LinearAlgebra", "Requires"]
git-tree-sha1 = "6a55b747d1812e699320963ffde36f1ebdda4099"
uuid = "79e6a3ab-5dfb-504d-930d-738a2a938a0e"
version = "4.0.4"
weakdeps = ["StaticArrays"]

    [deps.Adapt.extensions]
    AdaptStaticArraysExt = "StaticArrays"

[[deps.ArgCheck]]
git-tree-sha1 = "a3a402a35a2f7e0b87828ccabbd5ebfbebe356b4"
uuid = "dce04be8-c92d-5529-be00-80e4d2c0e197"
version = "2.3.0"

[[deps.ArgTools]]
uuid = "0dad84c5-d112-42e6-8d28-ef12dabb789f"
version = "1.1.1"

[[deps.Arpack]]
deps = ["Arpack_jll", "Libdl", "LinearAlgebra", "Logging"]
git-tree-sha1 = "9b9b347613394885fd1c8c7729bfc60528faa436"
uuid = "7d9fca2a-8960-54d3-9f78-7d1dccf2cb97"
version = "0.5.4"

[[deps.Arpack_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "OpenBLAS_jll", "Pkg"]
git-tree-sha1 = "5ba6c757e8feccf03a1554dfaf3e26b3cfc7fd5e"
uuid = "68821587-b530-5797-8361-c406ea357684"
version = "3.5.1+1"

[[deps.Artifacts]]
uuid = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"

[[deps.Atomix]]
deps = ["UnsafeAtomics"]
git-tree-sha1 = "c06a868224ecba914baa6942988e2f2aade419be"
uuid = "a9b6321e-bd34-4604-b9c9-b65b8de01458"
version = "0.1.0"

[[deps.AxisAlgorithms]]
deps = ["LinearAlgebra", "Random", "SparseArrays", "WoodburyMatrices"]
git-tree-sha1 = "01b8ccb13d68535d73d2b0c23e39bd23155fb712"
uuid = "13072b0f-2c55-5437-9ae7-d433b7a33950"
version = "1.1.0"

[[deps.BangBang]]
deps = ["Compat", "ConstructionBase", "InitialValues", "LinearAlgebra", "Requires", "Setfield", "Tables"]
git-tree-sha1 = "7aa7ad1682f3d5754e3491bb59b8103cae28e3a3"
uuid = "198e06fe-97b7-11e9-32a5-e1d131e6ad66"
version = "0.3.40"

    [deps.BangBang.extensions]
    BangBangChainRulesCoreExt = "ChainRulesCore"
    BangBangDataFramesExt = "DataFrames"
    BangBangStaticArraysExt = "StaticArrays"
    BangBangStructArraysExt = "StructArrays"
    BangBangTypedTablesExt = "TypedTables"

    [deps.BangBang.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"
    StructArrays = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
    TypedTables = "9d95f2ec-7b3d-5a63-8d20-e2491e220bb9"

[[deps.Base64]]
uuid = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"

[[deps.Baselet]]
git-tree-sha1 = "aebf55e6d7795e02ca500a689d326ac979aaf89e"
uuid = "9718e550-a3fa-408a-8086-8db961cd8217"
version = "0.1.1"

[[deps.BitFlags]]
git-tree-sha1 = "2dc09997850d68179b69dafb58ae806167a32b1b"
uuid = "d1d4a3ce-64b1-5f1a-9ba4-7e7e69966f35"
version = "0.1.8"

[[deps.Bzip2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "9e2a6b69137e6969bab0152632dcb3bc108c8bdd"
uuid = "6e34b625-4abd-537c-b88f-471c36dfa7a0"
version = "1.0.8+1"

[[deps.CEnum]]
git-tree-sha1 = "389ad5c84de1ae7cf0e28e381131c98ea87d54fc"
uuid = "fa961155-64e5-5f13-b03f-caf6b980ea82"
version = "0.5.0"

[[deps.CSV]]
deps = ["CodecZlib", "Dates", "FilePathsBase", "InlineStrings", "Mmap", "Parsers", "PooledArrays", "PrecompileTools", "SentinelArrays", "Tables", "Unicode", "WeakRefStrings", "WorkerUtilities"]
git-tree-sha1 = "a44910ceb69b0d44fe262dd451ab11ead3ed0be8"
uuid = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
version = "0.10.13"

[[deps.Cairo_jll]]
deps = ["Artifacts", "Bzip2_jll", "CompilerSupportLibraries_jll", "Fontconfig_jll", "FreeType2_jll", "Glib_jll", "JLLWrappers", "LZO_jll", "Libdl", "Pixman_jll", "Xorg_libXext_jll", "Xorg_libXrender_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "a4c43f59baa34011e303e76f5c8c91bf58415aaf"
uuid = "83423d85-b0ee-5818-9007-b63ccbeb887a"
version = "1.18.0+1"

[[deps.Calculus]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "f641eb0a4f00c343bbc32346e1217b86f3ce9dad"
uuid = "49dc2e85-a5d0-5ad3-a950-438e2897f1b9"
version = "0.5.1"

[[deps.ChainRules]]
deps = ["Adapt", "ChainRulesCore", "Compat", "Distributed", "GPUArraysCore", "IrrationalConstants", "LinearAlgebra", "Random", "RealDot", "SparseArrays", "SparseInverseSubset", "Statistics", "StructArrays", "SuiteSparse"]
git-tree-sha1 = "3e79289d94b579d81618f4c7c974bb9390dab493"
uuid = "082447d4-558c-5d27-93f4-14fc19e9eca2"
version = "1.64.0"

[[deps.ChainRulesCore]]
deps = ["Compat", "LinearAlgebra"]
git-tree-sha1 = "575cd02e080939a33b6df6c5853d14924c08e35b"
uuid = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
version = "1.23.0"
weakdeps = ["SparseArrays"]

    [deps.ChainRulesCore.extensions]
    ChainRulesCoreSparseArraysExt = "SparseArrays"

[[deps.Clustering]]
deps = ["Distances", "LinearAlgebra", "NearestNeighbors", "Printf", "Random", "SparseArrays", "Statistics", "StatsBase"]
git-tree-sha1 = "9ebb045901e9bbf58767a9f34ff89831ed711aae"
uuid = "aaaa29a8-35af-508c-8bc3-b662a17a0fe5"
version = "0.15.7"

[[deps.CodecZlib]]
deps = ["TranscodingStreams", "Zlib_jll"]
git-tree-sha1 = "59939d8a997469ee05c4b4944560a820f9ba0d73"
uuid = "944b1d66-785c-5afd-91f1-9de20f533193"
version = "0.7.4"

[[deps.ColorSchemes]]
deps = ["ColorTypes", "ColorVectorSpace", "Colors", "FixedPointNumbers", "PrecompileTools", "Random"]
git-tree-sha1 = "67c1f244b991cad9b0aa4b7540fb758c2488b129"
uuid = "35d6a980-a343-548e-a6ea-1d62b119f2f4"
version = "3.24.0"

[[deps.ColorTypes]]
deps = ["FixedPointNumbers", "Random"]
git-tree-sha1 = "eb7f0f8307f71fac7c606984ea5fb2817275d6e4"
uuid = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
version = "0.11.4"

[[deps.ColorVectorSpace]]
deps = ["ColorTypes", "FixedPointNumbers", "LinearAlgebra", "Requires", "Statistics", "TensorCore"]
git-tree-sha1 = "a1f44953f2382ebb937d60dafbe2deea4bd23249"
uuid = "c3611d14-8923-5661-9e6a-0046d554d3a4"
version = "0.10.0"
weakdeps = ["SpecialFunctions"]

    [deps.ColorVectorSpace.extensions]
    SpecialFunctionsExt = "SpecialFunctions"

[[deps.Colors]]
deps = ["ColorTypes", "FixedPointNumbers", "Reexport"]
git-tree-sha1 = "fc08e5930ee9a4e03f84bfb5211cb54e7769758a"
uuid = "5ae59095-9a9b-59fe-a467-6f913c188581"
version = "0.12.10"

[[deps.CommonSubexpressions]]
deps = ["MacroTools", "Test"]
git-tree-sha1 = "7b8a93dba8af7e3b42fecabf646260105ac373f7"
uuid = "bbf7d656-a473-5ed7-a52c-81e309532950"
version = "0.3.0"

[[deps.Compat]]
deps = ["TOML", "UUIDs"]
git-tree-sha1 = "c955881e3c981181362ae4088b35995446298b80"
uuid = "34da2185-b29b-5c13-b0c7-acf172513d20"
version = "4.14.0"
weakdeps = ["Dates", "LinearAlgebra"]

    [deps.Compat.extensions]
    CompatLinearAlgebraExt = "LinearAlgebra"

[[deps.CompilerSupportLibraries_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "e66e0078-7015-5450-92f7-15fbd957f2ae"
version = "1.1.0+0"

[[deps.CompositionsBase]]
git-tree-sha1 = "802bb88cd69dfd1509f6670416bd4434015693ad"
uuid = "a33af91c-f02d-484b-be07-31d278c5ca2b"
version = "0.1.2"

    [deps.CompositionsBase.extensions]
    CompositionsBaseInverseFunctionsExt = "InverseFunctions"

    [deps.CompositionsBase.weakdeps]
    InverseFunctions = "3587e190-3f89-42d0-90ee-14403ec27112"

[[deps.ConcurrentUtilities]]
deps = ["Serialization", "Sockets"]
git-tree-sha1 = "6cbbd4d241d7e6579ab354737f4dd95ca43946e1"
uuid = "f0e56b4a-5159-44fe-b623-3e5288b988bb"
version = "2.4.1"

[[deps.ConstructionBase]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "260fd2400ed2dab602a7c15cf10c1933c59930a2"
uuid = "187b0558-2788-49d3-abe0-74a17ed4e7c9"
version = "1.5.5"

    [deps.ConstructionBase.extensions]
    ConstructionBaseIntervalSetsExt = "IntervalSets"
    ConstructionBaseStaticArraysExt = "StaticArrays"

    [deps.ConstructionBase.weakdeps]
    IntervalSets = "8197267c-284f-5f27-9208-e0e47529a953"
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"

[[deps.ContextVariablesX]]
deps = ["Compat", "Logging", "UUIDs"]
git-tree-sha1 = "25cc3803f1030ab855e383129dcd3dc294e322cc"
uuid = "6add18c4-b38d-439d-96f6-d6bc489c04c5"
version = "0.1.3"

[[deps.Contour]]
git-tree-sha1 = "439e35b0b36e2e5881738abc8857bd92ad6ff9a8"
uuid = "d38c429a-6771-53c6-b99e-75d170b6e991"
version = "0.6.3"

[[deps.Crayons]]
git-tree-sha1 = "249fe38abf76d48563e2f4556bebd215aa317e15"
uuid = "a8cc5b0e-0ffa-5ad4-8c14-923d3ee1735f"
version = "4.1.1"

[[deps.DataAPI]]
git-tree-sha1 = "abe83f3a2f1b857aac70ef8b269080af17764bbe"
uuid = "9a962f9c-6df0-11e9-0e5d-c546b8b5ee8a"
version = "1.16.0"

[[deps.DataFrames]]
deps = ["Compat", "DataAPI", "DataStructures", "Future", "InlineStrings", "InvertedIndices", "IteratorInterfaceExtensions", "LinearAlgebra", "Markdown", "Missings", "PooledArrays", "PrecompileTools", "PrettyTables", "Printf", "REPL", "Random", "Reexport", "SentinelArrays", "SortingAlgorithms", "Statistics", "TableTraits", "Tables", "Unicode"]
git-tree-sha1 = "04c738083f29f86e62c8afc341f0967d8717bdb8"
uuid = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
version = "1.6.1"

[[deps.DataStructures]]
deps = ["Compat", "InteractiveUtils", "OrderedCollections"]
git-tree-sha1 = "0f4b5d62a88d8f59003e43c25a8a90de9eb76317"
uuid = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
version = "0.18.18"

[[deps.DataValueInterfaces]]
git-tree-sha1 = "bfc1187b79289637fa0ef6d4436ebdfe6905cbd6"
uuid = "e2d170a0-9d28-54be-80f0-106bbe20a464"
version = "1.0.0"

[[deps.Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"

[[deps.DefineSingletons]]
git-tree-sha1 = "0fba8b706d0178b4dc7fd44a96a92382c9065c2c"
uuid = "244e2a9f-e319-4986-a169-4d1fe445cd52"
version = "0.1.2"

[[deps.DelimitedFiles]]
deps = ["Mmap"]
git-tree-sha1 = "9e2f36d3c96a820c678f2f1f1782582fcf685bae"
uuid = "8bb1440f-4735-579b-a4ab-409b98df4dab"
version = "1.9.1"

[[deps.DiffResults]]
deps = ["StaticArraysCore"]
git-tree-sha1 = "782dd5f4561f5d267313f23853baaaa4c52ea621"
uuid = "163ba53b-c6d8-5494-b064-1a9d43ac40c5"
version = "1.1.0"

[[deps.DiffRules]]
deps = ["IrrationalConstants", "LogExpFunctions", "NaNMath", "Random", "SpecialFunctions"]
git-tree-sha1 = "23163d55f885173722d1e4cf0f6110cdbaf7e272"
uuid = "b552c78f-8df3-52c6-915a-8e097449b14b"
version = "1.15.1"

[[deps.Distances]]
deps = ["LinearAlgebra", "Statistics", "StatsAPI"]
git-tree-sha1 = "66c4c81f259586e8f002eacebc177e1fb06363b0"
uuid = "b4f34e82-e78d-54a5-968a-f98e89d6e8f7"
version = "0.10.11"
weakdeps = ["ChainRulesCore", "SparseArrays"]

    [deps.Distances.extensions]
    DistancesChainRulesCoreExt = "ChainRulesCore"
    DistancesSparseArraysExt = "SparseArrays"

[[deps.Distributed]]
deps = ["Random", "Serialization", "Sockets"]
uuid = "8ba89e20-285c-5b6f-9357-94700520ee1b"

[[deps.Distributions]]
deps = ["FillArrays", "LinearAlgebra", "PDMats", "Printf", "QuadGK", "Random", "SpecialFunctions", "Statistics", "StatsAPI", "StatsBase", "StatsFuns"]
git-tree-sha1 = "7c302d7a5fec5214eb8a5a4c466dcf7a51fcf169"
uuid = "31c24e10-a181-5473-b8eb-7969acd0382f"
version = "0.25.107"

    [deps.Distributions.extensions]
    DistributionsChainRulesCoreExt = "ChainRulesCore"
    DistributionsDensityInterfaceExt = "DensityInterface"
    DistributionsTestExt = "Test"

    [deps.Distributions.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    DensityInterface = "b429d917-457f-4dbc-8f4c-0cc954292b1d"
    Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[[deps.DocStringExtensions]]
deps = ["LibGit2"]
git-tree-sha1 = "2fb1e02f2b635d0845df5d7c167fec4dd739b00d"
uuid = "ffbed154-4ef7-542d-bbb7-c09d3a79fcae"
version = "0.9.3"

[[deps.Downloads]]
deps = ["ArgTools", "FileWatching", "LibCURL", "NetworkOptions"]
uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
version = "1.6.0"

[[deps.DualNumbers]]
deps = ["Calculus", "NaNMath", "SpecialFunctions"]
git-tree-sha1 = "5837a837389fccf076445fce071c8ddaea35a566"
uuid = "fa6b7ba4-c1ee-5f82-b5fc-ecf0adba8f74"
version = "0.6.8"

[[deps.EpollShim_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "8e9441ee83492030ace98f9789a654a6d0b1f643"
uuid = "2702e6a9-849d-5ed8-8c21-79e8b8f9ee43"
version = "0.0.20230411+0"

[[deps.ExceptionUnwrapping]]
deps = ["Test"]
git-tree-sha1 = "dcb08a0d93ec0b1cdc4af184b26b591e9695423a"
uuid = "460bff9d-24e4-43bc-9d9f-a8973cb893f4"
version = "0.1.10"

[[deps.Expat_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "4558ab818dcceaab612d1bb8c19cee87eda2b83c"
uuid = "2e619515-83b5-522b-bb60-26c02a35a201"
version = "2.5.0+0"

[[deps.FFMPEG]]
deps = ["FFMPEG_jll"]
git-tree-sha1 = "b57e3acbe22f8484b4b5ff66a7499717fe1a9cc8"
uuid = "c87230d0-a227-11e9-1b43-d7ebe4e7570a"
version = "0.4.1"

[[deps.FFMPEG_jll]]
deps = ["Artifacts", "Bzip2_jll", "FreeType2_jll", "FriBidi_jll", "JLLWrappers", "LAME_jll", "Libdl", "Ogg_jll", "OpenSSL_jll", "Opus_jll", "PCRE2_jll", "Zlib_jll", "libaom_jll", "libass_jll", "libfdk_aac_jll", "libvorbis_jll", "x264_jll", "x265_jll"]
git-tree-sha1 = "466d45dc38e15794ec7d5d63ec03d776a9aff36e"
uuid = "b22a6f82-2f65-5046-a5b2-351ab43fb4e5"
version = "4.4.4+1"

[[deps.FFTW]]
deps = ["AbstractFFTs", "FFTW_jll", "LinearAlgebra", "MKL_jll", "Preferences", "Reexport"]
git-tree-sha1 = "4820348781ae578893311153d69049a93d05f39d"
uuid = "7a1cc6ca-52ef-59f5-83cd-3a7055c09341"
version = "1.8.0"

[[deps.FFTW_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "c6033cc3892d0ef5bb9cd29b7f2f0331ea5184ea"
uuid = "f5851436-0d7a-5f13-b9de-f02708fd171a"
version = "3.3.10+0"

[[deps.FLoops]]
deps = ["BangBang", "Compat", "FLoopsBase", "InitialValues", "JuliaVariables", "MLStyle", "Serialization", "Setfield", "Transducers"]
git-tree-sha1 = "ffb97765602e3cbe59a0589d237bf07f245a8576"
uuid = "cc61a311-1640-44b5-9fba-1b764f453329"
version = "0.2.1"

[[deps.FLoopsBase]]
deps = ["ContextVariablesX"]
git-tree-sha1 = "656f7a6859be8673bf1f35da5670246b923964f7"
uuid = "b9860ae5-e623-471e-878b-f6a53c775ea6"
version = "0.1.1"

[[deps.FilePathsBase]]
deps = ["Compat", "Dates", "Mmap", "Printf", "Test", "UUIDs"]
git-tree-sha1 = "9f00e42f8d99fdde64d40c8ea5d14269a2e2c1aa"
uuid = "48062228-2e41-5def-b9a4-89aafe57970f"
version = "0.9.21"

[[deps.FileWatching]]
uuid = "7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"

[[deps.FillArrays]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "bfe82a708416cf00b73a3198db0859c82f741558"
uuid = "1a297f60-69ca-5386-bcde-b61e274b549b"
version = "1.10.0"
weakdeps = ["PDMats", "SparseArrays", "Statistics"]

    [deps.FillArrays.extensions]
    FillArraysPDMatsExt = "PDMats"
    FillArraysSparseArraysExt = "SparseArrays"
    FillArraysStatisticsExt = "Statistics"

[[deps.FixedPointNumbers]]
deps = ["Statistics"]
git-tree-sha1 = "335bfdceacc84c5cdf16aadc768aa5ddfc5383cc"
uuid = "53c48c17-4a7d-5ca2-90c5-79b7896eea93"
version = "0.8.4"

[[deps.Flux]]
deps = ["Adapt", "ChainRulesCore", "Compat", "Functors", "LinearAlgebra", "MLUtils", "MacroTools", "NNlib", "OneHotArrays", "Optimisers", "Preferences", "ProgressLogging", "Random", "Reexport", "SparseArrays", "SpecialFunctions", "Statistics", "Zygote"]
git-tree-sha1 = "a5475163b611812d073171583982c42ea48d22b0"
uuid = "587475ba-b771-5e3f-ad9e-33799f191a9c"
version = "0.14.15"

    [deps.Flux.extensions]
    FluxAMDGPUExt = "AMDGPU"
    FluxCUDAExt = "CUDA"
    FluxCUDAcuDNNExt = ["CUDA", "cuDNN"]
    FluxMetalExt = "Metal"

    [deps.Flux.weakdeps]
    AMDGPU = "21141c5a-9bdb-4563-92ae-f87d6854732e"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    Metal = "dde4c033-4e86-420c-a63e-0dd931031962"
    cuDNN = "02a925ec-e4fe-4b08-9a7e-0d78e3d38ccd"

[[deps.Fontconfig_jll]]
deps = ["Artifacts", "Bzip2_jll", "Expat_jll", "FreeType2_jll", "JLLWrappers", "Libdl", "Libuuid_jll", "Pkg", "Zlib_jll"]
git-tree-sha1 = "21efd19106a55620a188615da6d3d06cd7f6ee03"
uuid = "a3f928ae-7b40-5064-980b-68af3947d34b"
version = "2.13.93+0"

[[deps.Format]]
git-tree-sha1 = "9c68794ef81b08086aeb32eeaf33531668d5f5fc"
uuid = "1fa38f19-a742-5d3f-a2b9-30dd87b9d5f8"
version = "1.3.7"

[[deps.ForwardDiff]]
deps = ["CommonSubexpressions", "DiffResults", "DiffRules", "LinearAlgebra", "LogExpFunctions", "NaNMath", "Preferences", "Printf", "Random", "SpecialFunctions"]
git-tree-sha1 = "cf0fe81336da9fb90944683b8c41984b08793dad"
uuid = "f6369f11-7733-5829-9624-2563aa707210"
version = "0.10.36"
weakdeps = ["StaticArrays"]

    [deps.ForwardDiff.extensions]
    ForwardDiffStaticArraysExt = "StaticArrays"

[[deps.FreeType2_jll]]
deps = ["Artifacts", "Bzip2_jll", "JLLWrappers", "Libdl", "Zlib_jll"]
git-tree-sha1 = "d8db6a5a2fe1381c1ea4ef2cab7c69c2de7f9ea0"
uuid = "d7e528f0-a631-5988-bf34-fe36492bcfd7"
version = "2.13.1+0"

[[deps.FriBidi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "aa31987c2ba8704e23c6c8ba8a4f769d5d7e4f91"
uuid = "559328eb-81f9-559d-9380-de523a88c83c"
version = "1.0.10+0"

[[deps.Functors]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "d3e63d9fa13f8eaa2f06f64949e2afc593ff52c2"
uuid = "d9f16b24-f501-4c13-a1f2-28368ffc5196"
version = "0.4.10"

[[deps.Future]]
deps = ["Random"]
uuid = "9fa8497b-333b-5362-9e8d-4d0656e87820"

[[deps.GLFW_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libglvnd_jll", "Xorg_libXcursor_jll", "Xorg_libXi_jll", "Xorg_libXinerama_jll", "Xorg_libXrandr_jll"]
git-tree-sha1 = "ff38ba61beff76b8f4acad8ab0c97ef73bb670cb"
uuid = "0656b61e-2033-5cc2-a64a-77c0f6c09b89"
version = "3.3.9+0"

[[deps.GPUArrays]]
deps = ["Adapt", "GPUArraysCore", "LLVM", "LinearAlgebra", "Printf", "Random", "Reexport", "Serialization", "Statistics"]
git-tree-sha1 = "68e8ff56a4a355a85d2784b94614491f8c900cde"
uuid = "0c68f7d7-f131-5f86-a1c3-88cf8149b2d7"
version = "10.1.0"

[[deps.GPUArraysCore]]
deps = ["Adapt"]
git-tree-sha1 = "ec632f177c0d990e64d955ccc1b8c04c485a0950"
uuid = "46192b85-c4d5-4398-a991-12ede77f4527"
version = "0.1.6"

[[deps.GR]]
deps = ["Artifacts", "Base64", "DelimitedFiles", "Downloads", "GR_jll", "HTTP", "JSON", "Libdl", "LinearAlgebra", "Pkg", "Preferences", "Printf", "Random", "Serialization", "Sockets", "TOML", "Tar", "Test", "UUIDs", "p7zip_jll"]
git-tree-sha1 = "3437ade7073682993e092ca570ad68a2aba26983"
uuid = "28b8d3ca-fb5f-59d9-8090-bfdbd6d07a71"
version = "0.73.3"

[[deps.GR_jll]]
deps = ["Artifacts", "Bzip2_jll", "Cairo_jll", "FFMPEG_jll", "Fontconfig_jll", "FreeType2_jll", "GLFW_jll", "JLLWrappers", "JpegTurbo_jll", "Libdl", "Libtiff_jll", "Pixman_jll", "Qt6Base_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "a96d5c713e6aa28c242b0d25c1347e258d6541ab"
uuid = "d2c73de3-f751-5644-a686-071e5b155ba9"
version = "0.73.3+0"

[[deps.Gettext_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Libiconv_jll", "Pkg", "XML2_jll"]
git-tree-sha1 = "9b02998aba7bf074d14de89f9d37ca24a1a0b046"
uuid = "78b55507-aeef-58d4-861c-77aaff3498b1"
version = "0.21.0+0"

[[deps.Glib_jll]]
deps = ["Artifacts", "Gettext_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Libiconv_jll", "Libmount_jll", "PCRE2_jll", "Zlib_jll"]
git-tree-sha1 = "359a1ba2e320790ddbe4ee8b4d54a305c0ea2aff"
uuid = "7746bdde-850d-59dc-9ae8-88ece973131d"
version = "2.80.0+0"

[[deps.Graphite2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "344bf40dcab1073aca04aa0df4fb092f920e4011"
uuid = "3b182d85-2403-5c21-9c21-1e1f0cc25472"
version = "1.3.14+0"

[[deps.Grisu]]
git-tree-sha1 = "53bb909d1151e57e2484c3d1b53e19552b887fb2"
uuid = "42e2da0e-8278-4e71-bc24-59509adca0fe"
version = "1.0.2"

[[deps.HTTP]]
deps = ["Base64", "CodecZlib", "ConcurrentUtilities", "Dates", "ExceptionUnwrapping", "Logging", "LoggingExtras", "MbedTLS", "NetworkOptions", "OpenSSL", "Random", "SimpleBufferStream", "Sockets", "URIs", "UUIDs"]
git-tree-sha1 = "8e59b47b9dc525b70550ca082ce85bcd7f5477cd"
uuid = "cd3eb016-35fb-5094-929b-558a96fad6f3"
version = "1.10.5"

[[deps.HarfBuzz_jll]]
deps = ["Artifacts", "Cairo_jll", "Fontconfig_jll", "FreeType2_jll", "Glib_jll", "Graphite2_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Pkg"]
git-tree-sha1 = "129acf094d168394e80ee1dc4bc06ec835e510a3"
uuid = "2e76f6c2-a576-52d4-95c1-20adfe4de566"
version = "2.8.1+1"

[[deps.HypergeometricFunctions]]
deps = ["DualNumbers", "LinearAlgebra", "OpenLibm_jll", "SpecialFunctions"]
git-tree-sha1 = "f218fe3736ddf977e0e772bc9a586b2383da2685"
uuid = "34004b35-14d8-5ef3-9330-4cdb6864b03a"
version = "0.3.23"

[[deps.Hyperscript]]
deps = ["Test"]
git-tree-sha1 = "179267cfa5e712760cd43dcae385d7ea90cc25a4"
uuid = "47d2ed2b-36de-50cf-bf87-49c2cf4b8b91"
version = "0.0.5"

[[deps.HypertextLiteral]]
deps = ["Tricks"]
git-tree-sha1 = "7134810b1afce04bbc1045ca1985fbe81ce17653"
uuid = "ac1192a8-f4b3-4bfe-ba22-af5b92cd3ab2"
version = "0.9.5"

[[deps.IOCapture]]
deps = ["Logging", "Random"]
git-tree-sha1 = "8b72179abc660bfab5e28472e019392b97d0985c"
uuid = "b5f81e59-6552-4d32-b1f0-c071b021bf89"
version = "0.2.4"

[[deps.IRTools]]
deps = ["InteractiveUtils", "MacroTools", "Test"]
git-tree-sha1 = "5d8c5713f38f7bc029e26627b687710ba406d0dd"
uuid = "7869d1d1-7146-5819-86e3-90919afe41df"
version = "0.4.12"

[[deps.InitialValues]]
git-tree-sha1 = "4da0f88e9a39111c2fa3add390ab15f3a44f3ca3"
uuid = "22cec73e-a1b8-11e9-2c92-598750a2cf9c"
version = "0.3.1"

[[deps.InlineStrings]]
deps = ["Parsers"]
git-tree-sha1 = "9cc2baf75c6d09f9da536ddf58eb2f29dedaf461"
uuid = "842dd82b-1e85-43dc-bf29-5d0ee9dffc48"
version = "1.4.0"

[[deps.IntelOpenMP_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "5fdf2fe6724d8caabf43b557b84ce53f3b7e2f6b"
uuid = "1d5cc7b8-4909-519e-a0f8-d0f5ad9712d0"
version = "2024.0.2+0"

[[deps.InteractiveUtils]]
deps = ["Markdown"]
uuid = "b77e0a4c-d291-57a0-90e8-8db25a27a240"

[[deps.Interpolations]]
deps = ["Adapt", "AxisAlgorithms", "ChainRulesCore", "LinearAlgebra", "OffsetArrays", "Random", "Ratios", "Requires", "SharedArrays", "SparseArrays", "StaticArrays", "WoodburyMatrices"]
git-tree-sha1 = "88a101217d7cb38a7b481ccd50d21876e1d1b0e0"
uuid = "a98d9a8b-a2ab-59e6-89dd-64a1c18fca59"
version = "0.15.1"
weakdeps = ["Unitful"]

    [deps.Interpolations.extensions]
    InterpolationsUnitfulExt = "Unitful"

[[deps.InvertedIndices]]
git-tree-sha1 = "0dc7b50b8d436461be01300fd8cd45aa0274b038"
uuid = "41ab1584-1d38-5bbf-9106-f11c6c58b48f"
version = "1.3.0"

[[deps.IrrationalConstants]]
git-tree-sha1 = "630b497eafcc20001bba38a4651b327dcfc491d2"
uuid = "92d709cd-6900-40b7-9082-c6be49f344b6"
version = "0.2.2"

[[deps.IteratorInterfaceExtensions]]
git-tree-sha1 = "a3f24677c21f5bbe9d2a714f95dcd58337fb2856"
uuid = "82899510-4779-5014-852e-03e436cf321d"
version = "1.0.0"

[[deps.JLFzf]]
deps = ["Pipe", "REPL", "Random", "fzf_jll"]
git-tree-sha1 = "a53ebe394b71470c7f97c2e7e170d51df21b17af"
uuid = "1019f520-868f-41f5-a6de-eb00f4b6a39c"
version = "0.1.7"

[[deps.JLLWrappers]]
deps = ["Artifacts", "Preferences"]
git-tree-sha1 = "7e5d6779a1e09a36db2a7b6cff50942a0a7d0fca"
uuid = "692b3bcd-3c85-4b1f-b108-f13ce0eb3210"
version = "1.5.0"

[[deps.JSON]]
deps = ["Dates", "Mmap", "Parsers", "Unicode"]
git-tree-sha1 = "31e996f0a15c7b280ba9f76636b3ff9e2ae58c9a"
uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
version = "0.21.4"

[[deps.JpegTurbo_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "3336abae9a713d2210bb57ab484b1e065edd7d23"
uuid = "aacddb02-875f-59d6-b918-886e6ef4fbf8"
version = "3.0.2+0"

[[deps.JuliaVariables]]
deps = ["MLStyle", "NameResolution"]
git-tree-sha1 = "49fb3cb53362ddadb4415e9b73926d6b40709e70"
uuid = "b14d175d-62b4-44ba-8fb7-3064adc8c3ec"
version = "0.2.4"

[[deps.KernelAbstractions]]
deps = ["Adapt", "Atomix", "InteractiveUtils", "LinearAlgebra", "MacroTools", "PrecompileTools", "Requires", "SparseArrays", "StaticArrays", "UUIDs", "UnsafeAtomics", "UnsafeAtomicsLLVM"]
git-tree-sha1 = "ed7167240f40e62d97c1f5f7735dea6de3cc5c49"
uuid = "63c18a36-062a-441e-b654-da1e3ab1ce7c"
version = "0.9.18"

    [deps.KernelAbstractions.extensions]
    EnzymeExt = "EnzymeCore"

    [deps.KernelAbstractions.weakdeps]
    EnzymeCore = "f151be2c-9106-41f4-ab19-57ee4f262869"

[[deps.KernelDensity]]
deps = ["Distributions", "DocStringExtensions", "FFTW", "Interpolations", "StatsBase"]
git-tree-sha1 = "fee018a29b60733876eb557804b5b109dd3dd8a7"
uuid = "5ab0869b-81aa-558d-bb23-cbf5423bbe9b"
version = "0.6.8"

[[deps.LAME_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "f6250b16881adf048549549fba48b1161acdac8c"
uuid = "c1c5ebd0-6772-5130-a774-d5fcae4a789d"
version = "3.100.1+0"

[[deps.LERC_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "bf36f528eec6634efc60d7ec062008f171071434"
uuid = "88015f11-f218-50d7-93a8-a6af411a945d"
version = "3.0.0+1"

[[deps.LLVM]]
deps = ["CEnum", "LLVMExtra_jll", "Libdl", "Preferences", "Printf", "Requires", "Unicode"]
git-tree-sha1 = "839c82932db86740ae729779e610f07a1640be9a"
uuid = "929cbde3-209d-540e-8aea-75f648917ca0"
version = "6.6.3"

    [deps.LLVM.extensions]
    BFloat16sExt = "BFloat16s"

    [deps.LLVM.weakdeps]
    BFloat16s = "ab4f0b2a-ad5b-11e8-123f-65d77653426b"

[[deps.LLVMExtra_jll]]
deps = ["Artifacts", "JLLWrappers", "LazyArtifacts", "Libdl", "TOML"]
git-tree-sha1 = "88b916503aac4fb7f701bb625cd84ca5dd1677bc"
uuid = "dad2f222-ce93-54a1-a47d-0025e8a3acab"
version = "0.0.29+0"

[[deps.LLVMOpenMP_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "d986ce2d884d49126836ea94ed5bfb0f12679713"
uuid = "1d63c593-3942-5779-bab2-d838dc0a180e"
version = "15.0.7+0"

[[deps.LZO_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "e5b909bcf985c5e2605737d2ce278ed791b89be6"
uuid = "dd4b983a-f0e5-5f8d-a1b7-129d4a5fb1ac"
version = "2.10.1+0"

[[deps.LaTeXStrings]]
git-tree-sha1 = "50901ebc375ed41dbf8058da26f9de442febbbec"
uuid = "b964fa9f-0449-5b57-a5c2-d3ea65f4040f"
version = "1.3.1"

[[deps.Latexify]]
deps = ["Format", "InteractiveUtils", "LaTeXStrings", "MacroTools", "Markdown", "OrderedCollections", "Requires"]
git-tree-sha1 = "cad560042a7cc108f5a4c24ea1431a9221f22c1b"
uuid = "23fbe1c1-3f47-55db-b15f-69d7ec21a316"
version = "0.16.2"

    [deps.Latexify.extensions]
    DataFramesExt = "DataFrames"
    SymEngineExt = "SymEngine"

    [deps.Latexify.weakdeps]
    DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
    SymEngine = "123dc426-2d89-5057-bbad-38513e3affd8"

[[deps.LazyArtifacts]]
deps = ["Artifacts", "Pkg"]
uuid = "4af54fe1-eca0-43a8-85a7-787d91b784e3"

[[deps.LibCURL]]
deps = ["LibCURL_jll", "MozillaCACerts_jll"]
uuid = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"
version = "0.6.4"

[[deps.LibCURL_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "MbedTLS_jll", "Zlib_jll", "nghttp2_jll"]
uuid = "deac9b47-8bc7-5906-a0fe-35ac56dc84c0"
version = "8.4.0+0"

[[deps.LibGit2]]
deps = ["Base64", "LibGit2_jll", "NetworkOptions", "Printf", "SHA"]
uuid = "76f85450-5226-5b5a-8eaa-529ad045b433"

[[deps.LibGit2_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "MbedTLS_jll"]
uuid = "e37daf67-58a4-590a-8e99-b0245dd2ffc5"
version = "1.6.4+0"

[[deps.LibSSH2_jll]]
deps = ["Artifacts", "Libdl", "MbedTLS_jll"]
uuid = "29816b5a-b9ab-546f-933c-edad1886dfa8"
version = "1.11.0+1"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"

[[deps.Libffi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "0b4a5d71f3e5200a7dff793393e09dfc2d874290"
uuid = "e9f186c6-92d2-5b65-8a66-fee21dc1b490"
version = "3.2.2+1"

[[deps.Libgcrypt_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libgpg_error_jll", "Pkg"]
git-tree-sha1 = "64613c82a59c120435c067c2b809fc61cf5166ae"
uuid = "d4300ac3-e22c-5743-9152-c294e39db1e4"
version = "1.8.7+0"

[[deps.Libglvnd_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll", "Xorg_libXext_jll"]
git-tree-sha1 = "6f73d1dd803986947b2c750138528a999a6c7733"
uuid = "7e76a0d4-f3c7-5321-8279-8d96eeed0f29"
version = "1.6.0+0"

[[deps.Libgpg_error_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "c333716e46366857753e273ce6a69ee0945a6db9"
uuid = "7add5ba3-2f88-524e-9cd5-f83b8a55f7b8"
version = "1.42.0+0"

[[deps.Libiconv_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "f9557a255370125b405568f9767d6d195822a175"
uuid = "94ce4f54-9a6c-5748-9c1c-f9c7231a4531"
version = "1.17.0+0"

[[deps.Libmount_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "dae976433497a2f841baadea93d27e68f1a12a97"
uuid = "4b2f31a3-9ecc-558c-b454-b3730dcb73e9"
version = "2.39.3+0"

[[deps.Libtiff_jll]]
deps = ["Artifacts", "JLLWrappers", "JpegTurbo_jll", "LERC_jll", "Libdl", "XZ_jll", "Zlib_jll", "Zstd_jll"]
git-tree-sha1 = "2da088d113af58221c52828a80378e16be7d037a"
uuid = "89763e89-9b03-5906-acba-b20f662cd828"
version = "4.5.1+1"

[[deps.Libuuid_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "0a04a1318df1bf510beb2562cf90fb0c386f58c4"
uuid = "38a345b3-de98-5d2b-a5d3-14cd9215e700"
version = "2.39.3+1"

[[deps.LinearAlgebra]]
deps = ["Libdl", "OpenBLAS_jll", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

[[deps.LogExpFunctions]]
deps = ["DocStringExtensions", "IrrationalConstants", "LinearAlgebra"]
git-tree-sha1 = "18144f3e9cbe9b15b070288eef858f71b291ce37"
uuid = "2ab3a3ac-af41-5b50-aa03-7779005ae688"
version = "0.3.27"

    [deps.LogExpFunctions.extensions]
    LogExpFunctionsChainRulesCoreExt = "ChainRulesCore"
    LogExpFunctionsChangesOfVariablesExt = "ChangesOfVariables"
    LogExpFunctionsInverseFunctionsExt = "InverseFunctions"

    [deps.LogExpFunctions.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    ChangesOfVariables = "9e997f8a-9a97-42d5-a9f1-ce6bfc15e2c0"
    InverseFunctions = "3587e190-3f89-42d0-90ee-14403ec27112"

[[deps.Logging]]
uuid = "56ddb016-857b-54e1-b83d-db4d58db5568"

[[deps.LoggingExtras]]
deps = ["Dates", "Logging"]
git-tree-sha1 = "c1dd6d7978c12545b4179fb6153b9250c96b0075"
uuid = "e6f89c97-d47a-5376-807f-9c37f3926c36"
version = "1.0.3"

[[deps.MIMEs]]
git-tree-sha1 = "65f28ad4b594aebe22157d6fac869786a255b7eb"
uuid = "6c6e2e6c-3030-632d-7369-2d6c69616d65"
version = "0.1.4"

[[deps.MKL_jll]]
deps = ["Artifacts", "IntelOpenMP_jll", "JLLWrappers", "LazyArtifacts", "Libdl"]
git-tree-sha1 = "72dc3cf284559eb8f53aa593fe62cb33f83ed0c0"
uuid = "856f044c-d86e-5d09-b602-aeab76dc8ba7"
version = "2024.0.0+0"

[[deps.MLStyle]]
git-tree-sha1 = "bc38dff0548128765760c79eb7388a4b37fae2c8"
uuid = "d8e11817-5142-5d16-987a-aa16d5891078"
version = "0.4.17"

[[deps.MLUtils]]
deps = ["ChainRulesCore", "Compat", "DataAPI", "DelimitedFiles", "FLoops", "NNlib", "Random", "ShowCases", "SimpleTraits", "Statistics", "StatsBase", "Tables", "Transducers"]
git-tree-sha1 = "b45738c2e3d0d402dffa32b2c1654759a2ac35a4"
uuid = "f1d291b0-491e-4a28-83b9-f70985020b54"
version = "0.4.4"

[[deps.MacroTools]]
deps = ["Markdown", "Random"]
git-tree-sha1 = "2fa9ee3e63fd3a4f7a9a4f4744a52f4856de82df"
uuid = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
version = "0.5.13"

[[deps.Markdown]]
deps = ["Base64"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"

[[deps.MbedTLS]]
deps = ["Dates", "MbedTLS_jll", "MozillaCACerts_jll", "NetworkOptions", "Random", "Sockets"]
git-tree-sha1 = "c067a280ddc25f196b5e7df3877c6b226d390aaf"
uuid = "739be429-bea8-5141-9913-cc70e7f3736d"
version = "1.1.9"

[[deps.MbedTLS_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "c8ffd9c3-330d-5841-b78e-0817d7145fa1"
version = "2.28.2+1"

[[deps.Measures]]
git-tree-sha1 = "c13304c81eec1ed3af7fc20e75fb6b26092a1102"
uuid = "442fdcdd-2543-5da2-b0f3-8c86c306513e"
version = "0.3.2"

[[deps.MicroCollections]]
deps = ["BangBang", "InitialValues", "Setfield"]
git-tree-sha1 = "629afd7d10dbc6935ec59b32daeb33bc4460a42e"
uuid = "128add7d-3638-4c79-886c-908ea0c25c34"
version = "0.1.4"

[[deps.Missings]]
deps = ["DataAPI"]
git-tree-sha1 = "f66bdc5de519e8f8ae43bdc598782d35a25b1272"
uuid = "e1d29d7a-bbdc-5cf2-9ac0-f12de2c33e28"
version = "1.1.0"

[[deps.Mmap]]
uuid = "a63ad114-7e13-5084-954f-fe012c677804"

[[deps.MozillaCACerts_jll]]
uuid = "14a3606d-f60d-562e-9121-12d972cd8159"
version = "2023.1.10"

[[deps.MultivariateStats]]
deps = ["Arpack", "LinearAlgebra", "SparseArrays", "Statistics", "StatsAPI", "StatsBase"]
git-tree-sha1 = "68bf5103e002c44adfd71fea6bd770b3f0586843"
uuid = "6f286f6a-111f-5878-ab1e-185364afe411"
version = "0.10.2"

[[deps.NNlib]]
deps = ["Adapt", "Atomix", "ChainRulesCore", "GPUArraysCore", "KernelAbstractions", "LinearAlgebra", "Pkg", "Random", "Requires", "Statistics"]
git-tree-sha1 = "1fa1a14766c60e66ab22e242d45c1857c83a3805"
uuid = "872c559c-99b0-510c-b3b7-b6c96a88d5cd"
version = "0.9.13"

    [deps.NNlib.extensions]
    NNlibAMDGPUExt = "AMDGPU"
    NNlibCUDACUDNNExt = ["CUDA", "cuDNN"]
    NNlibCUDAExt = "CUDA"
    NNlibEnzymeCoreExt = "EnzymeCore"

    [deps.NNlib.weakdeps]
    AMDGPU = "21141c5a-9bdb-4563-92ae-f87d6854732e"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    EnzymeCore = "f151be2c-9106-41f4-ab19-57ee4f262869"
    cuDNN = "02a925ec-e4fe-4b08-9a7e-0d78e3d38ccd"

[[deps.NaNMath]]
deps = ["OpenLibm_jll"]
git-tree-sha1 = "0877504529a3e5c3343c6f8b4c0381e57e4387e4"
uuid = "77ba4419-2d1f-58cd-9bb1-8ffee604a2e3"
version = "1.0.2"

[[deps.NameResolution]]
deps = ["PrettyPrint"]
git-tree-sha1 = "1a0fa0e9613f46c9b8c11eee38ebb4f590013c5e"
uuid = "71a1bf82-56d0-4bbc-8a3c-48b961074391"
version = "0.1.5"

[[deps.NearestNeighbors]]
deps = ["Distances", "StaticArrays"]
git-tree-sha1 = "ded64ff6d4fdd1cb68dfcbb818c69e144a5b2e4c"
uuid = "b8a86587-4115-5ab1-83bc-aa920d37bbce"
version = "0.4.16"

[[deps.NetworkOptions]]
uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"
version = "1.2.0"

[[deps.Observables]]
git-tree-sha1 = "7438a59546cf62428fc9d1bc94729146d37a7225"
uuid = "510215fc-4207-5dde-b226-833fc4488ee2"
version = "0.5.5"

[[deps.OffsetArrays]]
git-tree-sha1 = "6a731f2b5c03157418a20c12195eb4b74c8f8621"
uuid = "6fe1bfb0-de20-5000-8ca7-80f57d26f881"
version = "1.13.0"
weakdeps = ["Adapt"]

    [deps.OffsetArrays.extensions]
    OffsetArraysAdaptExt = "Adapt"

[[deps.Ogg_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "887579a3eb005446d514ab7aeac5d1d027658b8f"
uuid = "e7412a2a-1a6e-54c0-be00-318e2571c051"
version = "1.3.5+1"

[[deps.OneHotArrays]]
deps = ["Adapt", "ChainRulesCore", "Compat", "GPUArraysCore", "LinearAlgebra", "NNlib"]
git-tree-sha1 = "963a3f28a2e65bb87a68033ea4a616002406037d"
uuid = "0b1bfda6-eb8a-41d2-88d8-f5af5cad476f"
version = "0.2.5"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.23+4"

[[deps.OpenLibm_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "05823500-19ac-5b8b-9628-191a04bc5112"
version = "0.8.1+2"

[[deps.OpenSSL]]
deps = ["BitFlags", "Dates", "MozillaCACerts_jll", "OpenSSL_jll", "Sockets"]
git-tree-sha1 = "af81a32750ebc831ee28bdaaba6e1067decef51e"
uuid = "4d8831e6-92b7-49fb-bdf8-b643e874388c"
version = "1.4.2"

[[deps.OpenSSL_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "3da7367955dcc5c54c1ba4d402ccdc09a1a3e046"
uuid = "458c3c95-2e84-50aa-8efc-19380b2a3a95"
version = "3.0.13+1"

[[deps.OpenSpecFun_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "13652491f6856acfd2db29360e1bbcd4565d04f1"
uuid = "efe28fd5-8261-553b-a9e1-b2916fc3738e"
version = "0.5.5+0"

[[deps.Optimisers]]
deps = ["ChainRulesCore", "Functors", "LinearAlgebra", "Random", "Statistics"]
git-tree-sha1 = "6572fe0c5b74431aaeb0b18a4aa5ef03c84678be"
uuid = "3bd65402-5787-11e9-1adc-39752487f4e2"
version = "0.3.3"

[[deps.Opus_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "51a08fb14ec28da2ec7a927c4337e4332c2a4720"
uuid = "91d4177d-7536-5919-b921-800302f37372"
version = "1.3.2+0"

[[deps.OrderedCollections]]
git-tree-sha1 = "dfdf5519f235516220579f949664f1bf44e741c5"
uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
version = "1.6.3"

[[deps.PCRE2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "efcefdf7-47ab-520b-bdef-62a2eaa19f15"
version = "10.42.0+1"

[[deps.PDMats]]
deps = ["LinearAlgebra", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "949347156c25054de2db3b166c52ac4728cbad65"
uuid = "90014a1f-27ba-587c-ab20-58faa44d9150"
version = "0.11.31"

[[deps.Parsers]]
deps = ["Dates", "PrecompileTools", "UUIDs"]
git-tree-sha1 = "8489905bcdbcfac64d1daa51ca07c0d8f0283821"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.8.1"

[[deps.Pipe]]
git-tree-sha1 = "6842804e7867b115ca9de748a0cf6b364523c16d"
uuid = "b98c9c47-44ae-5843-9183-064241ee97a0"
version = "1.3.0"

[[deps.Pixman_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "LLVMOpenMP_jll", "Libdl"]
git-tree-sha1 = "64779bc4c9784fee475689a1752ef4d5747c5e87"
uuid = "30392449-352a-5448-841d-b1acce4e97dc"
version = "0.42.2+0"

[[deps.Pkg]]
deps = ["Artifacts", "Dates", "Downloads", "FileWatching", "LibGit2", "Libdl", "Logging", "Markdown", "Printf", "REPL", "Random", "SHA", "Serialization", "TOML", "Tar", "UUIDs", "p7zip_jll"]
uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
version = "1.10.0"

[[deps.PlotThemes]]
deps = ["PlotUtils", "Statistics"]
git-tree-sha1 = "1f03a2d339f42dca4a4da149c7e15e9b896ad899"
uuid = "ccf2f8ad-2431-5c83-bf29-c5338b663b6a"
version = "3.1.0"

[[deps.PlotUtils]]
deps = ["ColorSchemes", "Colors", "Dates", "PrecompileTools", "Printf", "Random", "Reexport", "Statistics"]
git-tree-sha1 = "7b1a9df27f072ac4c9c7cbe5efb198489258d1f5"
uuid = "995b91a9-d308-5afd-9ec6-746e21dbc043"
version = "1.4.1"

[[deps.Plots]]
deps = ["Base64", "Contour", "Dates", "Downloads", "FFMPEG", "FixedPointNumbers", "GR", "JLFzf", "JSON", "LaTeXStrings", "Latexify", "LinearAlgebra", "Measures", "NaNMath", "Pkg", "PlotThemes", "PlotUtils", "PrecompileTools", "Printf", "REPL", "Random", "RecipesBase", "RecipesPipeline", "Reexport", "RelocatableFolders", "Requires", "Scratch", "Showoff", "SparseArrays", "Statistics", "StatsBase", "UUIDs", "UnicodeFun", "UnitfulLatexify", "Unzip"]
git-tree-sha1 = "3bdfa4fa528ef21287ef659a89d686e8a1bcb1a9"
uuid = "91a5bcdd-55d7-5caf-9e0b-520d859cae80"
version = "1.40.3"

    [deps.Plots.extensions]
    FileIOExt = "FileIO"
    GeometryBasicsExt = "GeometryBasics"
    IJuliaExt = "IJulia"
    ImageInTerminalExt = "ImageInTerminal"
    UnitfulExt = "Unitful"

    [deps.Plots.weakdeps]
    FileIO = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
    GeometryBasics = "5c1252a2-5f33-56bf-86c9-59e7332b4326"
    IJulia = "7073ff75-c697-5162-941a-fcdaad2a7d2a"
    ImageInTerminal = "d8c32880-2388-543b-8c61-d9f865259254"
    Unitful = "1986cc42-f94f-5a68-af5c-568840ba703d"

[[deps.PlutoUI]]
deps = ["AbstractPlutoDingetjes", "Base64", "ColorTypes", "Dates", "FixedPointNumbers", "Hyperscript", "HypertextLiteral", "IOCapture", "InteractiveUtils", "JSON", "Logging", "MIMEs", "Markdown", "Random", "Reexport", "URIs", "UUIDs"]
git-tree-sha1 = "71a22244e352aa8c5f0f2adde4150f62368a3f2e"
uuid = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
version = "0.7.58"

[[deps.PooledArrays]]
deps = ["DataAPI", "Future"]
git-tree-sha1 = "36d8b4b899628fb92c2749eb488d884a926614d3"
uuid = "2dfb63ee-cc39-5dd5-95bd-886bf059d720"
version = "1.4.3"

[[deps.PrecompileTools]]
deps = ["Preferences"]
git-tree-sha1 = "5aa36f7049a63a1528fe8f7c3f2113413ffd4e1f"
uuid = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
version = "1.2.1"

[[deps.Preferences]]
deps = ["TOML"]
git-tree-sha1 = "9306f6085165d270f7e3db02af26a400d580f5c6"
uuid = "21216c6a-2e73-6563-6e65-726566657250"
version = "1.4.3"

[[deps.PrettyPrint]]
git-tree-sha1 = "632eb4abab3449ab30c5e1afaa874f0b98b586e4"
uuid = "8162dcfd-2161-5ef2-ae6c-7681170c5f98"
version = "0.2.0"

[[deps.PrettyTables]]
deps = ["Crayons", "LaTeXStrings", "Markdown", "PrecompileTools", "Printf", "Reexport", "StringManipulation", "Tables"]
git-tree-sha1 = "88b895d13d53b5577fd53379d913b9ab9ac82660"
uuid = "08abe8d2-0d0c-5749-adfa-8a2ac140af0d"
version = "2.3.1"

[[deps.Printf]]
deps = ["Unicode"]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"

[[deps.ProgressLogging]]
deps = ["Logging", "SHA", "UUIDs"]
git-tree-sha1 = "80d919dee55b9c50e8d9e2da5eeafff3fe58b539"
uuid = "33c8b6b6-d38a-422a-b730-caa89a2f386c"
version = "0.1.4"

[[deps.Qt6Base_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Fontconfig_jll", "Glib_jll", "JLLWrappers", "Libdl", "Libglvnd_jll", "OpenSSL_jll", "Vulkan_Loader_jll", "Xorg_libSM_jll", "Xorg_libXext_jll", "Xorg_libXrender_jll", "Xorg_libxcb_jll", "Xorg_xcb_util_cursor_jll", "Xorg_xcb_util_image_jll", "Xorg_xcb_util_keysyms_jll", "Xorg_xcb_util_renderutil_jll", "Xorg_xcb_util_wm_jll", "Zlib_jll", "libinput_jll", "xkbcommon_jll"]
git-tree-sha1 = "37b7bb7aabf9a085e0044307e1717436117f2b3b"
uuid = "c0090381-4147-56d7-9ebc-da0b1113ec56"
version = "6.5.3+1"

[[deps.QuadGK]]
deps = ["DataStructures", "LinearAlgebra"]
git-tree-sha1 = "9b23c31e76e333e6fb4c1595ae6afa74966a729e"
uuid = "1fd47b50-473d-5c70-9696-f719f8f3bcdc"
version = "2.9.4"

[[deps.REPL]]
deps = ["InteractiveUtils", "Markdown", "Sockets", "Unicode"]
uuid = "3fa0cd96-eef1-5676-8a61-b3b8758bbffb"

[[deps.Random]]
deps = ["SHA"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"

[[deps.Ratios]]
deps = ["Requires"]
git-tree-sha1 = "1342a47bf3260ee108163042310d26f2be5ec90b"
uuid = "c84ed2f1-dad5-54f0-aa8e-dbefe2724439"
version = "0.4.5"
weakdeps = ["FixedPointNumbers"]

    [deps.Ratios.extensions]
    RatiosFixedPointNumbersExt = "FixedPointNumbers"

[[deps.RealDot]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "9f0a1b71baaf7650f4fa8a1d168c7fb6ee41f0c9"
uuid = "c1ae055f-0cd5-4b69-90a6-9a35b1a98df9"
version = "0.1.0"

[[deps.RecipesBase]]
deps = ["PrecompileTools"]
git-tree-sha1 = "5c3d09cc4f31f5fc6af001c250bf1278733100ff"
uuid = "3cdcf5f2-1ef4-517c-9805-6587b60abb01"
version = "1.3.4"

[[deps.RecipesPipeline]]
deps = ["Dates", "NaNMath", "PlotUtils", "PrecompileTools", "RecipesBase"]
git-tree-sha1 = "45cf9fd0ca5839d06ef333c8201714e888486342"
uuid = "01d81517-befc-4cb6-b9ec-a95719d0359c"
version = "0.6.12"

[[deps.Reexport]]
git-tree-sha1 = "45e428421666073eab6f2da5c9d310d99bb12f9b"
uuid = "189a3867-3050-52da-a836-e630ba90ab69"
version = "1.2.2"

[[deps.RelocatableFolders]]
deps = ["SHA", "Scratch"]
git-tree-sha1 = "ffdaf70d81cf6ff22c2b6e733c900c3321cab864"
uuid = "05181044-ff0b-4ac5-8273-598c1e38db00"
version = "1.0.1"

[[deps.Requires]]
deps = ["UUIDs"]
git-tree-sha1 = "838a3a4188e2ded87a4f9f184b4b0d78a1e91cb7"
uuid = "ae029012-a4dd-5104-9daa-d747884805df"
version = "1.3.0"

[[deps.Rmath]]
deps = ["Random", "Rmath_jll"]
git-tree-sha1 = "f65dcb5fa46aee0cf9ed6274ccbd597adc49aa7b"
uuid = "79098fc4-a85e-5d69-aa6a-4863f24498fa"
version = "0.7.1"

[[deps.Rmath_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "6ed52fdd3382cf21947b15e8870ac0ddbff736da"
uuid = "f50d1b31-88e8-58de-be2c-1cc44531875f"
version = "0.4.0+0"

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "0.7.0"

[[deps.Scratch]]
deps = ["Dates"]
git-tree-sha1 = "3bac05bc7e74a75fd9cba4295cde4045d9fe2386"
uuid = "6c6a2e73-6563-6170-7368-637461726353"
version = "1.2.1"

[[deps.SentinelArrays]]
deps = ["Dates", "Random"]
git-tree-sha1 = "0e7508ff27ba32f26cd459474ca2ede1bc10991f"
uuid = "91c51154-3ec4-41a3-a24f-3f23e20d615c"
version = "1.4.1"

[[deps.Serialization]]
uuid = "9e88b42a-f829-5b0c-bbe9-9e923198166b"

[[deps.Setfield]]
deps = ["ConstructionBase", "Future", "MacroTools", "StaticArraysCore"]
git-tree-sha1 = "e2cc6d8c88613c05e1defb55170bf5ff211fbeac"
uuid = "efcf1570-3423-57d1-acb7-fd33fddbac46"
version = "1.1.1"

[[deps.SharedArrays]]
deps = ["Distributed", "Mmap", "Random", "Serialization"]
uuid = "1a1011a3-84de-559e-8e89-a11a2f7dc383"

[[deps.ShowCases]]
git-tree-sha1 = "7f534ad62ab2bd48591bdeac81994ea8c445e4a5"
uuid = "605ecd9f-84a6-4c9e-81e2-4798472b76a3"
version = "0.1.0"

[[deps.Showoff]]
deps = ["Dates", "Grisu"]
git-tree-sha1 = "91eddf657aca81df9ae6ceb20b959ae5653ad1de"
uuid = "992d4aef-0814-514b-bc4d-f2e9a6c4116f"
version = "1.0.3"

[[deps.SimpleBufferStream]]
git-tree-sha1 = "874e8867b33a00e784c8a7e4b60afe9e037b74e1"
uuid = "777ac1f9-54b0-4bf8-805c-2214025038e7"
version = "1.1.0"

[[deps.SimpleTraits]]
deps = ["InteractiveUtils", "MacroTools"]
git-tree-sha1 = "5d7e3f4e11935503d3ecaf7186eac40602e7d231"
uuid = "699a6c99-e7fa-54fc-8d76-47d257e15c1d"
version = "0.9.4"

[[deps.Sockets]]
uuid = "6462fe0b-24de-5631-8697-dd941f90decc"

[[deps.SortingAlgorithms]]
deps = ["DataStructures"]
git-tree-sha1 = "66e0a8e672a0bdfca2c3f5937efb8538b9ddc085"
uuid = "a2af1166-a08f-5f64-846c-94a0d3cef48c"
version = "1.2.1"

[[deps.SparseArrays]]
deps = ["Libdl", "LinearAlgebra", "Random", "Serialization", "SuiteSparse_jll"]
uuid = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
version = "1.10.0"

[[deps.SparseInverseSubset]]
deps = ["LinearAlgebra", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "52962839426b75b3021296f7df242e40ecfc0852"
uuid = "dc90abb0-5640-4711-901d-7e5b23a2fada"
version = "0.1.2"

[[deps.SpecialFunctions]]
deps = ["IrrationalConstants", "LogExpFunctions", "OpenLibm_jll", "OpenSpecFun_jll"]
git-tree-sha1 = "e2cfc4012a19088254b3950b85c3c1d8882d864d"
uuid = "276daf66-3868-5448-9aa4-cd146d93841b"
version = "2.3.1"
weakdeps = ["ChainRulesCore"]

    [deps.SpecialFunctions.extensions]
    SpecialFunctionsChainRulesCoreExt = "ChainRulesCore"

[[deps.SplittablesBase]]
deps = ["Setfield", "Test"]
git-tree-sha1 = "e08a62abc517eb79667d0a29dc08a3b589516bb5"
uuid = "171d559e-b47b-412a-8079-5efa626c420e"
version = "0.1.15"

[[deps.StaticArrays]]
deps = ["LinearAlgebra", "PrecompileTools", "Random", "StaticArraysCore"]
git-tree-sha1 = "bf074c045d3d5ffd956fa0a461da38a44685d6b2"
uuid = "90137ffa-7385-5640-81b9-e52037218182"
version = "1.9.3"
weakdeps = ["ChainRulesCore", "Statistics"]

    [deps.StaticArrays.extensions]
    StaticArraysChainRulesCoreExt = "ChainRulesCore"
    StaticArraysStatisticsExt = "Statistics"

[[deps.StaticArraysCore]]
git-tree-sha1 = "36b3d696ce6366023a0ea192b4cd442268995a0d"
uuid = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
version = "1.4.2"

[[deps.Statistics]]
deps = ["LinearAlgebra", "SparseArrays"]
uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
version = "1.10.0"

[[deps.StatsAPI]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "1ff449ad350c9c4cbc756624d6f8a8c3ef56d3ed"
uuid = "82ae8749-77ed-4fe6-ae5f-f523153014b0"
version = "1.7.0"

[[deps.StatsBase]]
deps = ["DataAPI", "DataStructures", "LinearAlgebra", "LogExpFunctions", "Missings", "Printf", "Random", "SortingAlgorithms", "SparseArrays", "Statistics", "StatsAPI"]
git-tree-sha1 = "d1bf48bfcc554a3761a133fe3a9bb01488e06916"
uuid = "2913bbd2-ae8a-5f71-8c99-4fb6c76f3a91"
version = "0.33.21"

[[deps.StatsFuns]]
deps = ["HypergeometricFunctions", "IrrationalConstants", "LogExpFunctions", "Reexport", "Rmath", "SpecialFunctions"]
git-tree-sha1 = "cef0472124fab0695b58ca35a77c6fb942fdab8a"
uuid = "4c63d2b9-4356-54db-8cca-17b64c39e42c"
version = "1.3.1"

    [deps.StatsFuns.extensions]
    StatsFunsChainRulesCoreExt = "ChainRulesCore"
    StatsFunsInverseFunctionsExt = "InverseFunctions"

    [deps.StatsFuns.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    InverseFunctions = "3587e190-3f89-42d0-90ee-14403ec27112"

[[deps.StatsPlots]]
deps = ["AbstractFFTs", "Clustering", "DataStructures", "Distributions", "Interpolations", "KernelDensity", "LinearAlgebra", "MultivariateStats", "NaNMath", "Observables", "Plots", "RecipesBase", "RecipesPipeline", "Reexport", "StatsBase", "TableOperations", "Tables", "Widgets"]
git-tree-sha1 = "3b1dcbf62e469a67f6733ae493401e53d92ff543"
uuid = "f3b207a7-027a-5e70-b257-86293d7955fd"
version = "0.15.7"

[[deps.StringManipulation]]
deps = ["PrecompileTools"]
git-tree-sha1 = "a04cabe79c5f01f4d723cc6704070ada0b9d46d5"
uuid = "892a3eda-7b42-436c-8928-eab12a02cf0e"
version = "0.3.4"

[[deps.StructArrays]]
deps = ["ConstructionBase", "DataAPI", "Tables"]
git-tree-sha1 = "f4dc295e983502292c4c3f951dbb4e985e35b3be"
uuid = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
version = "0.6.18"
weakdeps = ["Adapt", "GPUArraysCore", "SparseArrays", "StaticArrays"]

    [deps.StructArrays.extensions]
    StructArraysAdaptExt = "Adapt"
    StructArraysGPUArraysCoreExt = "GPUArraysCore"
    StructArraysSparseArraysExt = "SparseArrays"
    StructArraysStaticArraysExt = "StaticArrays"

[[deps.SuiteSparse]]
deps = ["Libdl", "LinearAlgebra", "Serialization", "SparseArrays"]
uuid = "4607b0f0-06f3-5cda-b6b1-a6196a1729e9"

[[deps.SuiteSparse_jll]]
deps = ["Artifacts", "Libdl", "libblastrampoline_jll"]
uuid = "bea87d4a-7f5b-5778-9afe-8cc45184846c"
version = "7.2.1+1"

[[deps.TOML]]
deps = ["Dates"]
uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
version = "1.0.3"

[[deps.TableOperations]]
deps = ["SentinelArrays", "Tables", "Test"]
git-tree-sha1 = "e383c87cf2a1dc41fa30c093b2a19877c83e1bc1"
uuid = "ab02a1b2-a7df-11e8-156e-fb1833f50b87"
version = "1.2.0"

[[deps.TableTraits]]
deps = ["IteratorInterfaceExtensions"]
git-tree-sha1 = "c06b2f539df1c6efa794486abfb6ed2022561a39"
uuid = "3783bdb8-4a98-5b6b-af9a-565f29a5fe9c"
version = "1.0.1"

[[deps.Tables]]
deps = ["DataAPI", "DataValueInterfaces", "IteratorInterfaceExtensions", "LinearAlgebra", "OrderedCollections", "TableTraits"]
git-tree-sha1 = "cb76cf677714c095e535e3501ac7954732aeea2d"
uuid = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"
version = "1.11.1"

[[deps.Tar]]
deps = ["ArgTools", "SHA"]
uuid = "a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"
version = "1.10.0"

[[deps.TensorCore]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "1feb45f88d133a655e001435632f019a9a1bcdb6"
uuid = "62fd8b95-f654-4bbd-a8a5-9c27f68ccd50"
version = "0.1.1"

[[deps.Test]]
deps = ["InteractiveUtils", "Logging", "Random", "Serialization"]
uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[[deps.TranscodingStreams]]
git-tree-sha1 = "71509f04d045ec714c4748c785a59045c3736349"
uuid = "3bb67fe8-82b1-5028-8e26-92a6c54297fa"
version = "0.10.7"
weakdeps = ["Random", "Test"]

    [deps.TranscodingStreams.extensions]
    TestExt = ["Test", "Random"]

[[deps.Transducers]]
deps = ["Adapt", "ArgCheck", "BangBang", "Baselet", "CompositionsBase", "ConstructionBase", "DefineSingletons", "Distributed", "InitialValues", "Logging", "Markdown", "MicroCollections", "Requires", "Setfield", "SplittablesBase", "Tables"]
git-tree-sha1 = "3064e780dbb8a9296ebb3af8f440f787bb5332af"
uuid = "28d57a85-8fef-5791-bfe6-a80928e7c999"
version = "0.4.80"

    [deps.Transducers.extensions]
    TransducersBlockArraysExt = "BlockArrays"
    TransducersDataFramesExt = "DataFrames"
    TransducersLazyArraysExt = "LazyArrays"
    TransducersOnlineStatsBaseExt = "OnlineStatsBase"
    TransducersReferenceablesExt = "Referenceables"

    [deps.Transducers.weakdeps]
    BlockArrays = "8e7c35d0-a365-5155-bbbb-fb81a777f24e"
    DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
    LazyArrays = "5078a376-72f3-5289-bfd5-ec5146d43c02"
    OnlineStatsBase = "925886fa-5bf2-5e8e-b522-a9147a512338"
    Referenceables = "42d2dcc6-99eb-4e98-b66c-637b7d73030e"

[[deps.Tricks]]
git-tree-sha1 = "eae1bb484cd63b36999ee58be2de6c178105112f"
uuid = "410a4b4d-49e4-4fbc-ab6d-cb71b17b3775"
version = "0.1.8"

[[deps.URIs]]
git-tree-sha1 = "67db6cc7b3821e19ebe75791a9dd19c9b1188f2b"
uuid = "5c2747f8-b7ea-4ff2-ba2e-563bfd36b1d4"
version = "1.5.1"

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"

[[deps.UnicodeFun]]
deps = ["REPL"]
git-tree-sha1 = "53915e50200959667e78a92a418594b428dffddf"
uuid = "1cfade01-22cf-5700-b092-accc4b62d6e1"
version = "0.4.1"

[[deps.Unitful]]
deps = ["Dates", "LinearAlgebra", "Random"]
git-tree-sha1 = "3c793be6df9dd77a0cf49d80984ef9ff996948fa"
uuid = "1986cc42-f94f-5a68-af5c-568840ba703d"
version = "1.19.0"

    [deps.Unitful.extensions]
    ConstructionBaseUnitfulExt = "ConstructionBase"
    InverseFunctionsUnitfulExt = "InverseFunctions"

    [deps.Unitful.weakdeps]
    ConstructionBase = "187b0558-2788-49d3-abe0-74a17ed4e7c9"
    InverseFunctions = "3587e190-3f89-42d0-90ee-14403ec27112"

[[deps.UnitfulLatexify]]
deps = ["LaTeXStrings", "Latexify", "Unitful"]
git-tree-sha1 = "e2d817cc500e960fdbafcf988ac8436ba3208bfd"
uuid = "45397f5d-5981-4c77-b2b3-fc36d6e9b728"
version = "1.6.3"

[[deps.UnsafeAtomics]]
git-tree-sha1 = "6331ac3440856ea1988316b46045303bef658278"
uuid = "013be700-e6cd-48c3-b4a1-df204f14c38f"
version = "0.2.1"

[[deps.UnsafeAtomicsLLVM]]
deps = ["LLVM", "UnsafeAtomics"]
git-tree-sha1 = "323e3d0acf5e78a56dfae7bd8928c989b4f3083e"
uuid = "d80eeb9a-aca5-4d75-85e5-170c8b632249"
version = "0.1.3"

[[deps.Unzip]]
git-tree-sha1 = "ca0969166a028236229f63514992fc073799bb78"
uuid = "41fe7b60-77ed-43a1-b4f0-825fd5a5650d"
version = "0.2.0"

[[deps.Vulkan_Loader_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Wayland_jll", "Xorg_libX11_jll", "Xorg_libXrandr_jll", "xkbcommon_jll"]
git-tree-sha1 = "2f0486047a07670caad3a81a075d2e518acc5c59"
uuid = "a44049a8-05dd-5a78-86c9-5fde0876e88c"
version = "1.3.243+0"

[[deps.Wayland_jll]]
deps = ["Artifacts", "EpollShim_jll", "Expat_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Pkg", "XML2_jll"]
git-tree-sha1 = "7558e29847e99bc3f04d6569e82d0f5c54460703"
uuid = "a2964d1f-97da-50d4-b82a-358c7fce9d89"
version = "1.21.0+1"

[[deps.Wayland_protocols_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "93f43ab61b16ddfb2fd3bb13b3ce241cafb0e6c9"
uuid = "2381bf8a-dfd0-557d-9999-79630e7b1b91"
version = "1.31.0+0"

[[deps.WeakRefStrings]]
deps = ["DataAPI", "InlineStrings", "Parsers"]
git-tree-sha1 = "b1be2855ed9ed8eac54e5caff2afcdb442d52c23"
uuid = "ea10d353-3f73-51f8-a26c-33c1cb351aa5"
version = "1.4.2"

[[deps.Widgets]]
deps = ["Colors", "Dates", "Observables", "OrderedCollections"]
git-tree-sha1 = "fcdae142c1cfc7d89de2d11e08721d0f2f86c98a"
uuid = "cc8bc4a8-27d6-5769-a93b-9d913e69aa62"
version = "0.6.6"

[[deps.WoodburyMatrices]]
deps = ["LinearAlgebra", "SparseArrays"]
git-tree-sha1 = "c1a7aa6219628fcd757dede0ca95e245c5cd9511"
uuid = "efce3f68-66dc-5838-9240-27a6d6f5f9b6"
version = "1.0.0"

[[deps.WorkerUtilities]]
git-tree-sha1 = "cd1659ba0d57b71a464a29e64dbc67cfe83d54e7"
uuid = "76eceee3-57b5-4d4a-8e66-0e911cebbf60"
version = "1.6.1"

[[deps.XML2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libiconv_jll", "Zlib_jll"]
git-tree-sha1 = "532e22cf7be8462035d092ff21fada7527e2c488"
uuid = "02c8fc9c-b97f-50b9-bbe4-9be30ff0a78a"
version = "2.12.6+0"

[[deps.XSLT_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libgcrypt_jll", "Libgpg_error_jll", "Libiconv_jll", "Pkg", "XML2_jll", "Zlib_jll"]
git-tree-sha1 = "91844873c4085240b95e795f692c4cec4d805f8a"
uuid = "aed1982a-8fda-507f-9586-7b0439959a61"
version = "1.1.34+0"

[[deps.XZ_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "ac88fb95ae6447c8dda6a5503f3bafd496ae8632"
uuid = "ffd25f8a-64ca-5728-b0f7-c24cf3aae800"
version = "5.4.6+0"

[[deps.Xorg_libICE_jll]]
deps = ["Libdl", "Pkg"]
git-tree-sha1 = "e5becd4411063bdcac16be8b66fc2f9f6f1e8fe5"
uuid = "f67eecfb-183a-506d-b269-f58e52b52d7c"
version = "1.0.10+1"

[[deps.Xorg_libSM_jll]]
deps = ["Libdl", "Pkg", "Xorg_libICE_jll"]
git-tree-sha1 = "4a9d9e4c180e1e8119b5ffc224a7b59d3a7f7e18"
uuid = "c834827a-8449-5923-a945-d239c165b7dd"
version = "1.2.3+0"

[[deps.Xorg_libX11_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libxcb_jll", "Xorg_xtrans_jll"]
git-tree-sha1 = "afead5aba5aa507ad5a3bf01f58f82c8d1403495"
uuid = "4f6342f7-b3d2-589e-9d20-edeb45f2b2bc"
version = "1.8.6+0"

[[deps.Xorg_libXau_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "6035850dcc70518ca32f012e46015b9beeda49d8"
uuid = "0c0b7dd1-d40b-584c-a123-a41640f87eec"
version = "1.0.11+0"

[[deps.Xorg_libXcursor_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXfixes_jll", "Xorg_libXrender_jll"]
git-tree-sha1 = "12e0eb3bc634fa2080c1c37fccf56f7c22989afd"
uuid = "935fb764-8cf2-53bf-bb30-45bb1f8bf724"
version = "1.2.0+4"

[[deps.Xorg_libXdmcp_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "34d526d318358a859d7de23da945578e8e8727b7"
uuid = "a3789734-cfe1-5b06-b2d0-1dd0d9d62d05"
version = "1.1.4+0"

[[deps.Xorg_libXext_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "b7c0aa8c376b31e4852b360222848637f481f8c3"
uuid = "1082639a-0dae-5f34-9b06-72781eeb8cb3"
version = "1.3.4+4"

[[deps.Xorg_libXfixes_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "0e0dc7431e7a0587559f9294aeec269471c991a4"
uuid = "d091e8ba-531a-589c-9de9-94069b037ed8"
version = "5.0.3+4"

[[deps.Xorg_libXi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXext_jll", "Xorg_libXfixes_jll"]
git-tree-sha1 = "89b52bc2160aadc84d707093930ef0bffa641246"
uuid = "a51aa0fd-4e3c-5386-b890-e753decda492"
version = "1.7.10+4"

[[deps.Xorg_libXinerama_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXext_jll"]
git-tree-sha1 = "26be8b1c342929259317d8b9f7b53bf2bb73b123"
uuid = "d1454406-59df-5ea1-beac-c340f2130bc3"
version = "1.1.4+4"

[[deps.Xorg_libXrandr_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXext_jll", "Xorg_libXrender_jll"]
git-tree-sha1 = "34cea83cb726fb58f325887bf0612c6b3fb17631"
uuid = "ec84b674-ba8e-5d96-8ba1-2a689ba10484"
version = "1.5.2+4"

[[deps.Xorg_libXrender_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "19560f30fd49f4d4efbe7002a1037f8c43d43b96"
uuid = "ea2f1a96-1ddc-540d-b46f-429655e07cfa"
version = "0.9.10+4"

[[deps.Xorg_libpthread_stubs_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "8fdda4c692503d44d04a0603d9ac0982054635f9"
uuid = "14d82f49-176c-5ed1-bb49-ad3f5cbd8c74"
version = "0.1.1+0"

[[deps.Xorg_libxcb_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "XSLT_jll", "Xorg_libXau_jll", "Xorg_libXdmcp_jll", "Xorg_libpthread_stubs_jll"]
git-tree-sha1 = "b4bfde5d5b652e22b9c790ad00af08b6d042b97d"
uuid = "c7cfdc94-dc32-55de-ac96-5a1b8d977c5b"
version = "1.15.0+0"

[[deps.Xorg_libxkbfile_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libX11_jll"]
git-tree-sha1 = "730eeca102434283c50ccf7d1ecdadf521a765a4"
uuid = "cc61e674-0454-545c-8b26-ed2c68acab7a"
version = "1.1.2+0"

[[deps.Xorg_xcb_util_cursor_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_xcb_util_image_jll", "Xorg_xcb_util_jll", "Xorg_xcb_util_renderutil_jll"]
git-tree-sha1 = "04341cb870f29dcd5e39055f895c39d016e18ccd"
uuid = "e920d4aa-a673-5f3a-b3d7-f755a4d47c43"
version = "0.1.4+0"

[[deps.Xorg_xcb_util_image_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "0fab0a40349ba1cba2c1da699243396ff8e94b97"
uuid = "12413925-8142-5f55-bb0e-6d7ca50bb09b"
version = "0.4.0+1"

[[deps.Xorg_xcb_util_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libxcb_jll"]
git-tree-sha1 = "e7fd7b2881fa2eaa72717420894d3938177862d1"
uuid = "2def613f-5ad1-5310-b15b-b15d46f528f5"
version = "0.4.0+1"

[[deps.Xorg_xcb_util_keysyms_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "d1151e2c45a544f32441a567d1690e701ec89b00"
uuid = "975044d2-76e6-5fbe-bf08-97ce7c6574c7"
version = "0.4.0+1"

[[deps.Xorg_xcb_util_renderutil_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "dfd7a8f38d4613b6a575253b3174dd991ca6183e"
uuid = "0d47668e-0667-5a69-a72c-f761630bfb7e"
version = "0.3.9+1"

[[deps.Xorg_xcb_util_wm_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "e78d10aab01a4a154142c5006ed44fd9e8e31b67"
uuid = "c22f9ab0-d5fe-5066-847c-f4bb1cd4e361"
version = "0.4.1+1"

[[deps.Xorg_xkbcomp_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libxkbfile_jll"]
git-tree-sha1 = "330f955bc41bb8f5270a369c473fc4a5a4e4d3cb"
uuid = "35661453-b289-5fab-8a00-3d9160c6a3a4"
version = "1.4.6+0"

[[deps.Xorg_xkeyboard_config_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_xkbcomp_jll"]
git-tree-sha1 = "691634e5453ad362044e2ad653e79f3ee3bb98c3"
uuid = "33bec58e-1273-512f-9401-5d533626f822"
version = "2.39.0+0"

[[deps.Xorg_xtrans_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "e92a1a012a10506618f10b7047e478403a046c77"
uuid = "c5fb5394-a638-5e4d-96e5-b29de1b5cf10"
version = "1.5.0+0"

[[deps.Zlib_jll]]
deps = ["Libdl"]
uuid = "83775a58-1f1d-513f-b197-d71354ab007a"
version = "1.2.13+1"

[[deps.Zstd_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "e678132f07ddb5bfa46857f0d7620fb9be675d3b"
uuid = "3161d3a3-bdf6-5164-811a-617609db77b4"
version = "1.5.6+0"

[[deps.Zygote]]
deps = ["AbstractFFTs", "ChainRules", "ChainRulesCore", "DiffRules", "Distributed", "FillArrays", "ForwardDiff", "GPUArrays", "GPUArraysCore", "IRTools", "InteractiveUtils", "LinearAlgebra", "LogExpFunctions", "MacroTools", "NaNMath", "PrecompileTools", "Random", "Requires", "SparseArrays", "SpecialFunctions", "Statistics", "ZygoteRules"]
git-tree-sha1 = "4ddb4470e47b0094c93055a3bcae799165cc68f1"
uuid = "e88e6eb3-aa80-5325-afca-941959d7151f"
version = "0.6.69"

    [deps.Zygote.extensions]
    ZygoteColorsExt = "Colors"
    ZygoteDistancesExt = "Distances"
    ZygoteTrackerExt = "Tracker"

    [deps.Zygote.weakdeps]
    Colors = "5ae59095-9a9b-59fe-a467-6f913c188581"
    Distances = "b4f34e82-e78d-54a5-968a-f98e89d6e8f7"
    Tracker = "9f7883ad-71c0-57eb-9f7f-b5c9e6d3789c"

[[deps.ZygoteRules]]
deps = ["ChainRulesCore", "MacroTools"]
git-tree-sha1 = "27798139afc0a2afa7b1824c206d5e87ea587a00"
uuid = "700de1a5-db45-46bc-99cf-38207098b444"
version = "0.2.5"

[[deps.eudev_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "gperf_jll"]
git-tree-sha1 = "431b678a28ebb559d224c0b6b6d01afce87c51ba"
uuid = "35ca27e7-8b34-5b7f-bca9-bdc33f59eb06"
version = "3.2.9+0"

[[deps.fzf_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "a68c9655fbe6dfcab3d972808f1aafec151ce3f8"
uuid = "214eeab7-80f7-51ab-84ad-2988db7cef09"
version = "0.43.0+0"

[[deps.gperf_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "3516a5630f741c9eecb3720b1ec9d8edc3ecc033"
uuid = "1a1c6b14-54f6-533d-8383-74cd7377aa70"
version = "3.1.1+0"

[[deps.libaom_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "3a2ea60308f0996d26f1e5354e10c24e9ef905d4"
uuid = "a4ae2306-e953-59d6-aa16-d00cac43593b"
version = "3.4.0+0"

[[deps.libass_jll]]
deps = ["Artifacts", "Bzip2_jll", "FreeType2_jll", "FriBidi_jll", "HarfBuzz_jll", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "5982a94fcba20f02f42ace44b9894ee2b140fe47"
uuid = "0ac62f75-1d6f-5e53-bd7c-93b484bb37c0"
version = "0.15.1+0"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.8.0+1"

[[deps.libevdev_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "141fe65dc3efabb0b1d5ba74e91f6ad26f84cc22"
uuid = "2db6ffa8-e38f-5e21-84af-90c45d0032cc"
version = "1.11.0+0"

[[deps.libfdk_aac_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "daacc84a041563f965be61859a36e17c4e4fcd55"
uuid = "f638f0a6-7fb0-5443-88ba-1cc74229b280"
version = "2.0.2+0"

[[deps.libinput_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "eudev_jll", "libevdev_jll", "mtdev_jll"]
git-tree-sha1 = "ad50e5b90f222cfe78aa3d5183a20a12de1322ce"
uuid = "36db933b-70db-51c0-b978-0f229ee0e533"
version = "1.18.0+0"

[[deps.libpng_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Zlib_jll"]
git-tree-sha1 = "d7015d2e18a5fd9a4f47de711837e980519781a4"
uuid = "b53b4c65-9356-5827-b1ea-8c7a1a84506f"
version = "1.6.43+1"

[[deps.libvorbis_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Ogg_jll", "Pkg"]
git-tree-sha1 = "b910cb81ef3fe6e78bf6acee440bda86fd6ae00c"
uuid = "f27f6e37-5d2b-51aa-960f-b287f2bc3b7a"
version = "1.3.7+1"

[[deps.mtdev_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "814e154bdb7be91d78b6802843f76b6ece642f11"
uuid = "009596ad-96f7-51b1-9f1b-5ce2d5e8a71e"
version = "1.1.6+0"

[[deps.nghttp2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850ede-7688-5339-a07c-302acd2aaf8d"
version = "1.52.0+1"

[[deps.p7zip_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "3f19e933-33d8-53b3-aaab-bd5110c3b7a0"
version = "17.4.0+2"

[[deps.x264_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "4fea590b89e6ec504593146bf8b988b2c00922b2"
uuid = "1270edf5-f2f9-52d2-97e9-ab00b5d0237a"
version = "2021.5.5+0"

[[deps.x265_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "ee567a171cce03570d77ad3a43e90218e38937a9"
uuid = "dfaa095f-4041-5dcd-9319-2fabd8486b76"
version = "3.5.0+0"

[[deps.xkbcommon_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Wayland_jll", "Wayland_protocols_jll", "Xorg_libxcb_jll", "Xorg_xkeyboard_config_jll"]
git-tree-sha1 = "9c304562909ab2bab0262639bd4f444d7bc2be37"
uuid = "d8fb68d0-12a3-5cfd-a85a-d49703b185fd"
version = "1.4.1+1"
"""

# ╔═╡ Cell order:
# ╠═d1856c6d-302c-4f13-9a3d-1c143fc0585d
# ╠═1431c33d-00cd-40be-a548-c473cf2be82c
# ╟─4694df35-d2d8-4d39-ba60-07a894357d09
# ╟─7773febb-95f8-4c44-8eda-98397a3b7ad0
# ╟─44f9d85c-3218-4c54-8308-d873119ed64a
# ╟─caf44cc1-e597-43c9-9db9-a34afca02a50
# ╟─b4381993-9840-4379-b124-428477ce474c
# ╟─5067d15f-2af0-4e45-83af-44f1adc840d4
# ╟─c8c89920-2466-4cf0-927a-d1fe927ecb1b
# ╟─40e49425-d5f1-4bf1-8a89-233cd26c0ad2
# ╟─4d6fe02c-78b7-45a0-b8da-1c6cd9712b84
# ╟─5d901945-77b9-4298-ae4c-7f89f3b5d87f
# ╟─b1178733-e724-4622-9cd7-3c3c4a58d44a
# ╠═1dc18c4d-5dbe-460d-ac84-28e1ac6dbab5
# ╠═2940b832-970b-4538-ab11-e2a3836226f2
# ╟─ba88b58c-da54-42be-960b-d9f364b3cc30
# ╟─c52230e8-68db-44cf-9116-88fd650ee9de
# ╟─b8d205f1-671c-4b78-acf3-fa90f8ae9998
# ╟─839b72dc-d0e3-41bf-abb0-4e930f9c48fe
# ╟─e35e969e-5aa3-4026-8335-6bf1dc2f8961
# ╟─df3d803a-4d52-41ef-82ae-2655217cb1b8
# ╟─013d8a03-aa87-45f9-bf39-4703a9ad56a1
# ╟─5d34fd78-ddad-4d38-9ac3-71c68e85480f
# ╟─87992e42-ed6a-478c-b468-a6017f2083c9
# ╟─8555d123-e074-4242-9138-75e63983b9d3
# ╟─c8a64528-2a86-4806-8949-949e0e12c5ff
# ╟─d513b0d2-8719-4328-86af-75d2b5bdc829
# ╟─2a9b7009-3ac7-4431-8806-af081d5435c2
# ╟─83f8334c-494a-412b-989e-0d7caf412d58
# ╟─e84757f5-eeed-4409-badc-899a2583a6bc
# ╟─a863584b-3611-4130-b162-7966859fb891
# ╟─772072d2-fc85-4ce5-8c10-294512978b81
# ╟─da3f2a32-653e-4ea0-8e14-f3731ba1b056
# ╟─79e81287-54af-4083-9de0-e82515ef7be3
# ╟─ee0b93ce-1baf-4b71-a23a-81c9279a4f8f
# ╟─470213e1-dc5e-4d32-acce-dff405aba7c2
# ╟─9aca9018-e6cc-48a6-adae-53d09cdb0339
# ╟─1806279a-0f67-4658-b5c9-1eebc6ed7919
# ╟─5f2308de-a8c6-4c36-9bb8-40da9f393bf7
# ╟─88622208-488a-419f-95d5-641f2a71d7e5
# ╟─35b76c76-9749-4070-ba4f-aafa10349250
# ╟─6cf2abfd-0652-4b0b-8d64-5896c058dc49
# ╟─d503570f-efff-4642-ab19-12a88699bc4a
# ╟─79337a1e-f774-42b9-9ce4-5f78b8dacd6c
# ╟─1f2ef155-c827-400f-8f34-9ead965a4831
# ╠═618271a1-3d80-4eb5-8902-5fdd7b3b648e
# ╠═160ebfa2-fd91-4ed9-8f6c-f1069aba5a9d
# ╠═6b5b8d8c-fb5a-42a5-bdb3-36829a16d52f
# ╠═fc7a63b1-1ed7-4567-9c08-dfeedb283d3b
# ╠═6070b6c9-4f91-4acb-ba65-880bcf4237b1
# ╟─6f987b3d-5726-41eb-8bd5-7a70f31e7af5
# ╟─9a9adfc7-e4cb-479b-a572-304cc0ad8cb5
# ╠═96c6f674-1a3b-47de-ab23-bd586fb70448
# ╠═9eb3bc1c-ea1c-4bec-ad7d-02b8f4ad81f0
# ╟─b92061c7-71c3-46dd-a5d7-0ec49511016b
# ╟─7960fc2d-3d6e-4060-ac80-6a5fd7723c7e
# ╟─290ba563-2207-49e9-b966-7b3088e17f79
# ╟─1ec722d8-853a-4394-8faa-3cba23c7db78
# ╟─f8ee81c8-ee45-49cb-8f60-4585573b9e9e
# ╟─2383bb87-2049-4a07-9b71-eba7b726c4d7
# ╠═fcf90c27-ab69-4b90-bada-ce30fd1dbd07
# ╟─f64e1a46-dd78-4e31-a5ea-b6b32fdaea81
# ╟─5216be48-4981-4388-b288-ea2353a165bd
# ╟─3bf6802f-e4a9-4c6d-b5ae-f9750bbe82c4
# ╠═d8048221-286d-413b-bb83-c8be118094e4
# ╟─08769354-34f9-4f3e-8b2a-f43278f38269
# ╟─c6d8f4ce-475e-4636-980f-faf07b3ebfd9
# ╠═cf1455b6-05da-4053-ab07-902153dc0958
# ╠═07563188-dbb1-4610-a62c-0fbaf6cf1d4f
# ╟─ae194c55-8529-4843-9f64-2dde07f08da8
# ╠═92e26370-e4f1-4b24-b48f-01384cd5a4d0
# ╟─4a84f584-18be-41a2-aab7-186204a09b03
# ╟─3b0b04c2-e89e-4e87-86f0-5a599ed04646
# ╟─52210b74-2957-481f-8f36-7b9bdf68c630
# ╟─7498d60f-8134-4b26-9579-1eea8b6667d9
# ╠═720e6b90-3e85-4c90-9c54-e8ae469a9cba
# ╟─cc545f2b-37b8-4f00-b551-8e41dfe0d532
# ╟─311f71fe-8096-4062-8ded-cfee8dd989b2
# ╟─e3d9321e-db98-4d28-8c9d-34aebf3fb6cb
# ╟─92b957dc-5244-4766-99b1-7c0ea470bef3
# ╟─c37ec15d-8968-486a-b625-cc337f09c4a5
# ╟─58156220-e508-444d-b4c1-34260fd98037
# ╟─7174cf2c-8cf9-4089-8951-5e52a43fe1e1
# ╟─da868574-1fc3-494c-b928-bf8c0e0832f7
# ╟─9365ff42-21d4-49da-be59-bbd0d8d78ca7
# ╟─3c23a6f7-78f3-4076-9e02-5a0b48c697cb
# ╟─a47837ac-8de8-42c9-8ea2-a3ef6619db4c
# ╟─080d2217-217e-4366-8275-07036daf777b
# ╟─3b627bcb-6b24-4caa-93d0-f0ec60d64f33
# ╟─b56b7c78-bbb4-4c3c-a49b-4069e809d99f
# ╟─c6a5c0c3-b7c7-4987-864b-b69eb48b4f21
# ╟─c42de5db-c9b2-4fc0-a8b5-53ce1a818e89
# ╟─7de3d275-eea4-487f-aa38-2462d440c05e
# ╟─6d0c90fc-b398-4a63-a129-e950ae84169c
# ╟─be60977b-84f5-4355-92d5-291843dedf8b
# ╟─7160f04d-d684-403f-8ede-9de2f5997f99
# ╟─de408642-0f01-4832-9e51-37895b3a5ccd
# ╟─8d1110e2-9940-4171-ade1-7eb3c83b9332
# ╟─4dd60134-242b-4857-aa69-56c55d0021f4
# ╟─114b88c0-27d6-49a9-ba44-d4f78a5d5611
# ╟─fc1bdd7b-3f20-415f-aac2-e1d87c1038f0
# ╠═3a3a0a71-ebb8-41e4-8d2f-c68c6daaf772
# ╟─f88ec603-6a91-4c2e-9ab1-9cb1aeb28ab4
# ╠═f4106179-42f4-4620-895c-cae10d81d8e6
# ╟─7707022c-7067-4611-b708-79814fab4564
# ╟─d45fe2a2-ca99-4af4-b2cd-86c0824a7cd8
# ╟─bf15eb86-ab97-417f-b6c1-2da5915bce56
# ╠═daed30c6-0d40-4d03-a33d-ff1f89ef9161
# ╠═d75c78d4-f545-4b52-a1d7-5c2ff570b172
# ╠═a805e6a0-58e0-4c06-8a3b-f9ffaf76bf0b
# ╠═7741430f-d27a-4adf-988c-5805bd69baae
# ╠═c01d54bb-c161-46ce-b64e-14a2a7c023d0
# ╟─ccee0fff-b4d7-4594-a2f5-b62318f51588
# ╟─c47ca169-b110-4691-bdcb-d2c0f13ea64d
# ╟─ca473b94-f00f-4ca0-a298-d4e8373aca3b
# ╟─252fd0dc-e692-4429-903c-fcf7058e3f0b
# ╟─66cdd4d2-9e24-442e-bec0-e2c6c8a226e4
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
