CREATE OR REPLACE FUNCTION epoch_to_jd(epoch DOUBLE PRECISION) RETURNS DOUBLE PRECISION
	LANGUAGE plpgsql
AS
$$
BEGIN
	RETURN (epoch / (24 * 3600) + 2440587.5); -- Julian Day starts at noon, hence the 0.5 addition
END;
$$;

-- ------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION date_to_jd(d DATE) RETURNS DOUBLE PRECISION
	LANGUAGE plpgsql
AS
$$
BEGIN
	RETURN epoch_to_jd(EXTRACT(EPOCH FROM d));
END;
$$;
-- ------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION jd_to_jalali(jd DOUBLE PRECISION)
	RETURNS TABLE
			(
				year  INTEGER,
				month INTEGER,
				day   INTEGER
			)
	LANGUAGE plpgsql
AS
$$
DECLARE
	depoch         DOUBLE PRECISION;
	cycle          INTEGER;
	cyear          INTEGER;
	ycycle         INTEGER;
	aux1           INTEGER;
	aux2           INTEGER;
	yday           INTEGER;
	epyear         INTEGER;
	days_in_months INTEGER;
BEGIN
	-- Step 1: Calculate the difference in days from the base Jalali epoch (475-01-01)
	depoch := jd - jalali_to_jd(475, 1, 1);

	-- Step 2: Calculate the cycle and year in cycle
	cycle := FLOOR(depoch / 1029983)::INTEGER;
	cyear := FLOOR(depoch)::INTEGER % 1029983;

	-- Step 3: Calculate the year in cycle
	IF cyear = 1029982 THEN
		ycycle := 2820;
	ELSE
		aux1 := FLOOR(cyear / 366);
		aux2 := cyear % 366;
		ycycle := ((2134 * aux1 + 2816 * aux2 + 2815) / 1028522) + aux1 + 1;
	END IF;

	-- Step 4: Calculate the Jalali year
	year := ycycle + 2820 * cycle + 474;
	IF year <= 0 THEN
		year := year - 1;
	END IF;

	-- Step 5: Calculate the day of the year in the Jalali calendar
	yday := FLOOR(jd) - jalali_to_jd(year, 1, 1) + 1;

	-- Step 6: Determine the Jalali month and day
	IF yday <= 186 THEN
		month := CEIL(yday / 31.0)::INTEGER;
		day := yday - 31 * (month - 1);
	ELSE
		month := CEIL((yday - 6) / 30.0)::INTEGER;
		day := yday - 186 - 30 * (month - 7);
	END IF;

	RETURN QUERY SELECT year, month, day;
END;
$$;

-- ------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION jalali_to_jd(year INTEGER, month INTEGER, day INTEGER) RETURNS INTEGER
	LANGUAGE plpgsql
AS
$$
DECLARE
	epbase         INT;
	epyear         INT;
	jd             INT;
	correction     DOUBLE PRECISION;
	days_in_months INT;
BEGIN
	IF year >= 0 THEN
		epbase := year - 474;
	ELSE
		epbase := year - 473;
	END IF;
	epyear := 474 + (epbase % 2820);

	correction := ((epyear * 682) - 110) / 2816;

	IF month <= 6 THEN
		days_in_months := (month - 1) * 31;
	ELSE
		days_in_months := 6 * 31 + (month - 7) * 30;
	END IF;

	jd := day +
		  days_in_months +
		  correction +
		  (epyear - 1) * 365 +
		  (epbase / 2820) * 1029983 +
		  1948320 - 1;


	RETURN jd;
END;
$$;



ALTER FUNCTION jalali_to_jd(INTEGER, INTEGER, INTEGER) OWNER TO metanext_user;

-- ------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION jalali_date_trunc(part TEXT, gregorian_date DATE) RETURNS DATE
	LANGUAGE plpgsql
AS
$$
DECLARE
	jd DOUBLE PRECISION;
	jalali_year INTEGER;
	jalali_month INTEGER;
	jalali_day INTEGER;
	day_of_week INTEGER;
	days_to_subtract INTEGER;
	truncated_jalali_date TEXT;
	result_date DATE;
BEGIN
	-- Step 1: Convert Gregorian date to Julian Day
	jd := date_to_jd(gregorian_date);

	-- Step 2: Convert Julian Day to Jalali date parts
	SELECT year, month, day
		INTO jalali_year, jalali_month, jalali_day
		FROM jd_to_jalali(jd);

	-- Step 3: Truncate the Jalali date based on the part (year, month, week)
	IF part = 'year' THEN
		truncated_jalali_date := format('%s-01-01', jalali_year);
	ELSIF part = 'month' THEN
		truncated_jalali_date := format('%s-%s-01', jalali_year, LPAD(jalali_month::TEXT, 2, '0'));
	ELSIF part = 'week' THEN
		-- Calculate the day of the week for the Julian Day (0=Saturday, 1=Sunday, ..., 6=Friday)
		day_of_week := FLOOR(jd + 1.5)::INT % 7;


		-- Calculate the number of days to subtract to get to the most recent Saturday
		days_to_subtract := (day_of_week + 1) % 7;


		-- Adjust the Jalali date to the most recent Saturday
		jalali_day := jalali_day - days_to_subtract;


		-- Correct for day overflow (when subtracting goes below the first of the month)
		WHILE jalali_day < 1 LOOP
				jalali_month := jalali_month - 1;
				IF jalali_month < 1 THEN
					jalali_month := 12;
					jalali_year := jalali_year - 1;
				END IF;
				jalali_day := jalali_day + CASE
											   WHEN jalali_month <= 6 THEN 31
											   WHEN jalali_month <= 11 THEN 30
											   ELSE 29 + (CASE WHEN MOD(jalali_year, 33) IN (1, 5, 9, 13, 17, 22, 26, 30) THEN 1 ELSE 0 END)
					END;

			END LOOP;


		truncated_jalali_date := format('%s-%s-%s', jalali_year, LPAD(jalali_month::TEXT, 2, '0'), LPAD(jalali_day::TEXT, 2, '0'));
	ELSE

	END IF;

	-- Step 6: Convert the truncated Jalali date back to Gregorian date
	result_date := jalali_to_gregorian(truncated_jalali_date);
	RETURN result_date;
END;
$$;





-- ------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION jalali_to_gregorian(jalali_date TEXT) RETURNS DATE AS
$$
DECLARE
	jd          INT;
	jd_adjusted INT;
BEGIN
	-- Convert Jalali date to Julian Day
	SELECT jalali_to_jd(
				   SPLIT_PART(jalali_date, '-', 1)::INT,
				   SPLIT_PART(jalali_date, '-', 2)::INT,
				   SPLIT_PART(jalali_date, '-', 3)::INT
		   )
		INTO jd;


	-- Adjust the Julian Day by 1
	jd_adjusted := jd + 1;

	-- Convert Julian Day to Gregorian date
	RETURN to_date(jd_adjusted::TEXT, 'J');
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------------------------------

-- Testing epoch_to_jd function
SELECT epoch_to_jd(EXTRACT(EPOCH FROM '1970-01-01'::DATE));
-- Should return 2440587.5

-- Testing date_to_jd function
SELECT date_to_jd('1970-01-01'::DATE);
-- Should return 2440587.5

-- Testing jd_to_jalali function with debug output
SELECT * FROM jd_to_jalali(2460024); -- Expected: (1402, 9, 24)
SELECT * FROM jd_to_jalali(date_to_jd('2023-12-16'::DATE));
-- Expected: (1402, 9, 25)


-- Testing jalali_to_jd function
SELECT jalali_to_jd(1402, 1, 1); -- Should correspond to 2460293 (Julian Day for 2023-12-15)
SELECT jalali_to_jd(1402, 9, 25);
-- Should correspond to 2460294 (Julian Day for 2023-12-16)

-- Testing truncation to the start of the year
SELECT jalali_date_trunc('year', '2023-12-15'::DATE);
-- Expected: Corresponding Gregorian date for 1402-01-01

-- Testing truncation to the start of the month
SELECT jalali_date_trunc('month', '2023-12-15'::DATE);
-- Expected: Corresponding Gregorian date for 1402-09-01

-- Testing truncation to the start of the week
SELECT jalali_date_trunc('week', '2023-12-1'::DATE); -- Expected: Corresponding Gregorian date for the most recent Saturday (2023-12-23)


-- Testing jalali_to_gregorian function
SELECT jalali_to_gregorian('1402-11-10'); -- Expected: Corresponding Gregorian date for 1402-01-01 in Jalali calendar
