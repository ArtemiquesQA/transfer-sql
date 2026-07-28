--
-- PostgreSQL database dump
--

-- Dumped from database version 15.6 (Debian 15.6-1.pgdg100+1)
-- Dumped by pg_dump version 15.3

-- Started on 2026-07-28 21:27:19

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- TOC entry 9 (class 2615 OID 804206)
-- Name: hb_debezium; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA hb_debezium;


--
-- TOC entry 4 (class 2615 OID 2200)
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- TOC entry 4110 (class 0 OID 0)
-- Dependencies: 4
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- TOC entry 6 (class 2615 OID 16601)
-- Name: sofk_application; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA sofk_application;


--
-- TOC entry 408 (class 1255 OID 570464)
-- Name: after_insert_customer_to_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.after_insert_customer_to_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                INSERT INTO tsss_queue(mdm_id, type, change_key)
                SELECT
                    c.mdm_id,
                    'VIP_TOP',
                    build_vip_top_change_key(c.id)
                FROM customer c
                WHERE c.id = NEW.id;

            RETURN NEW;
            END;
            $$;


--
-- TOC entry 406 (class 1255 OID 570462)
-- Name: build_service_team_change_key(bigint); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.build_service_team_change_key(customer_id_param bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
        DECLARE
            service_team_change_key JSON;
            BEGIN
            SELECT json_build_object(
                           'serviceGroup', gp.group_number,
                           'productType',
                           CASE
                               WHEN c.service_pack IN ('Прайм','Прайм+','Прайм NEW','Прайм базовый') THEN 'PRIME'
                               WHEN c.service_pack IN ('Привилегия','ПривилегияМК') THEN 'PRIVILEGE'
                               ELSE 'MULTICART'
                               END,
                           'team',
                           COALESCE(
                                   json_agg(
                                           json_build_object(
                                                   'employeeTabnum', e.pers_num,
                                                   'role',
                                                   CASE
                                                       WHEN cte.role_in_team = 'SUPERVISOR' THEN 'SUPERVISOR_PRIVILEGE'
                                                       WHEN cte.role_in_team = 'PFM' THEN 'PERSONAL_FINANCE_MANAGER1'
                                                       WHEN cte.role_in_team = 'PFM2' THEN 'PERSONAL_FINANCE_MANAGER2'
                                                       WHEN cte.role_in_team = 'BILL_ACCOUNTANT' THEN 'ACCOUNT_MANAGER'
                                                       WHEN cte.role_in_team = 'BILL_ACCOUNTANT_PRIVILEGE' THEN 'ACCOUNT_MANAGER_PRIVILEGE'
                                                       WHEN cte.role_in_team = 'SUPERVISOR_PRIME' THEN 'SUPERVISOR_PRIME'
                                                       WHEN cte.role_in_team = 'PERSONAL_MANAGER' THEN 'PERSONAL_MANAGER'
                                                       ELSE cte.role_in_team
                                                       END,
                                                   'branch', CASE WHEN b.ext_code = '' THEN '000000' ELSE b.ext_code END,
                                                   'shifter',
                                                   CASE
                                                       WHEN cte.shifter_id IS NULL or ts.id is null THEN NULL
                                                       ELSE json_build_object(
                                                               'employeeTabnum', shifter.pers_num,
                                                               'shiftStart', json_build_array(
                                                                       EXTRACT(YEAR FROM ts.start_date)::int,
                                                                       EXTRACT(MONTH FROM ts.start_date)::int,
                                                                       EXTRACT(DAY FROM ts.start_date)::int
                                                                             ),
                                                               'shiftEnd',
                                                               CASE
                                                                   WHEN ts.return_date IS NULL THEN NULL
                                                                   ELSE json_build_array(
                                                                           EXTRACT(YEAR FROM ts.return_date)::int,
                                                                           EXTRACT(MONTH FROM ts.return_date)::int,
                                                                           EXTRACT(DAY FROM ts.return_date)::int
                                                                        )
                                                                   END,
                                                               'shiftReason', ts.reason
                                                            )
                                                       END
                                           )
                                   ) FILTER (WHERE cte.id IS NOT NULL),
                                   '[]'::json
                           )
                   ) INTO service_team_change_key
            FROM customer c
                     LEFT JOIN customer_prime cp ON cp.customer_id = c.id
                     LEFT JOIN group_prime gp ON gp.id = cp.group_id
                     LEFT JOIN customer_to_employee cte ON cte.customer_id = c.id
                     LEFT JOIN employee e ON e.id = cte.service_team_member_id
                     LEFT JOIN branch b ON b.id = cte.branch_id
                     LEFT JOIN employee shifter ON shifter.id = cte.shifter_id
                     LEFT JOIN temporary_shift ts ON ts.customer_to_employee_id = cte.id
            WHERE c.id = customer_id_param
            GROUP BY gp.group_number, c.service_pack LIMIT 1;

            RETURN service_team_change_key;
            END;
        $$;


--
-- TOC entry 407 (class 1255 OID 570463)
-- Name: build_vip_top_change_key(bigint); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.build_vip_top_change_key(customer_id_param bigint) RETURNS json
    LANGUAGE plpgsql
    AS $$
            BEGIN
            RETURN
                (SELECT json_build_object(
                                'vip', CASE WHEN cp.vip = TRUE THEN TRUE ELSE FALSE END,
                                'top', CASE WHEN cp.top = TRUE THEN TRUE ELSE FALSE END,
                                'superVip', CASE WHEN svh.super_vip = TRUE THEN TRUE ELSE FALSE END,
                                'masterMdmId', kp.mdm_id,
                                'relativeExtCode', r.ext_code
                        )
                 FROM customer c
                          LEFT JOIN customer_prime cp ON cp.customer_id = c.id
                          LEFT JOIN super_vip_history svh ON svh.customer_id = c.id
                     AND svh.date_revoked IS NULL
                     AND svh.super_vip = TRUE
                          LEFT JOIN affiliates a ON a.affiliate_id = c.id
                          LEFT JOIN customer kp ON kp.id = a.master_id
                          LEFT JOIN "relative" r ON r.id = a.relative_id
                 WHERE c.id = customer_id_param LIMIT 1);
            END;
            $$;


--
-- TOC entry 375 (class 1255 OID 570404)
-- Name: customer_to_employee_assigned_date_on_rm(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.customer_to_employee_assigned_date_on_rm() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
                BEGIN
                IF (TG_OP = 'DELETE') THEN
                    IF (OLD.role_in_team = 'PERSONAL_MANAGER') THEN
                        UPDATE customer_to_employee
                        SET assigned_date = now()
                        where customer_id = OLD.customer_id;
                    ELSIF (OLD.role_in_team = 'PFM') THEN
                        UPDATE customer_to_employee
                        SET assigned_date = now()
                        where customer_id = OLD.customer_id
                            and role_in_team in ('SUPERVISOR_PRIME');
                    END IF;
                END IF;
                RETURN NULL; -- result is ignored since this is an AFTER trigger
                END;
                $$;


--
-- TOC entry 416 (class 1255 OID 570403)
-- Name: customer_to_employee_assigned_date_on_upd(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.customer_to_employee_assigned_date_on_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.service_team_member_id IS DISTINCT FROM OLD.service_team_member_id)) THEN
                IF (NEW.role_in_team = 'PERSONAL_MANAGER') THEN
                    UPDATE customer_to_employee
                    SET assigned_date = now()
                    where customer_id = NEW.customer_id
                        and role_in_team in ('SUPERVISOR', 'PERSONAL_MANAGER');
                ELSIF (NEW.role_in_team = 'PFM') THEN
                    UPDATE customer_to_employee
                    SET assigned_date = now()
                    where customer_id = NEW.customer_id
                        and role_in_team in ('SUPERVISOR_PRIME','PFM');
                ELSIF (NEW.role_in_team = 'PFM2') THEN
                    UPDATE customer_to_employee
                    SET assigned_date = now()
                    where customer_id = NEW.customer_id
                        and role_in_team = 'PFM2';
                ELSIF (NEW.role_in_team = 'BILL_ACCOUNTANT') THEN
                    UPDATE customer_to_employee
                    SET assigned_date = now()
                    where customer_id = NEW.customer_id
                        and role_in_team = 'BILL_ACCOUNTANT';
                ELSIF (NEW.role_in_team = 'BILL_ACCOUNTANT_PRIVILEGE') THEN
                    UPDATE customer_to_employee
                    SET assigned_date = now()
                    where customer_id = NEW.customer_id
                        and role_in_team = 'BILL_ACCOUNTANT_PRIVILEGE';
                END IF;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 414 (class 1255 OID 570488)
-- Name: forbid_update_customer_id(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.forbid_update_customer_id() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                -- Запрет на изменение customer_id в трёх таблицах
                IF TG_TABLE_NAME IN ('customer_to_employee', 'customer_prime', 'super_vip_history') THEN
                    IF NEW.customer_id IS DISTINCT FROM OLD.customer_id THEN
                        RAISE EXCEPTION 'Изменение поля customer_id в таблице % запрещено', TG_TABLE_NAME;
            END IF;
            END IF;

                -- Запрет на изменение master_id и affiliate_id в affiliates
                IF TG_TABLE_NAME = 'affiliates' THEN
                    IF NEW.master_id IS DISTINCT FROM OLD.master_id THEN
                        RAISE EXCEPTION 'Изменение поля master_id в таблице affiliates запрещено';
            END IF;
                    IF NEW.affiliate_id IS DISTINCT FROM OLD.affiliate_id THEN
                        RAISE EXCEPTION 'Изменение поля affiliate_id в таблице affiliates запрещено';
            END IF;
            END IF;

                -- Запрет на изменение id в customer
                IF TG_TABLE_NAME = 'customer' THEN
                    IF NEW.id IS DISTINCT FROM OLD.id THEN
                        RAISE EXCEPTION 'Изменение поля id в таблице customer запрещено';
            END IF;
            END IF;

            RETURN NEW;
            END;
            $$;


--
-- TOC entry 395 (class 1255 OID 569813)
-- Name: process_affiliates_audit(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_affiliates_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'DELETE') THEN
            INSERT INTO affiliates_audit(operation, stamp, userid, entity_id, master_id, affiliate_id, relative_id, specific_relation)
            SELECT 'D', now() at time zone 'utc', user, OLD.id, OLD.master_id, OLD.affiliate_id, OLD.relative_id, OLD.specific_relation;
            ELSIF (TG_OP = 'UPDATE') THEN
            INSERT INTO affiliates_audit(operation, stamp, userid, entity_id, master_id, affiliate_id, relative_id, specific_relation)
            SELECT 'U', now() at time zone 'utc', user, NEW.id, NEW.master_id, NEW.affiliate_id, NEW.relative_id, NEW.specific_relation;
            ELSIF (TG_OP = 'INSERT') THEN
            INSERT INTO affiliates_audit(operation, stamp, userid, entity_id, master_id, affiliate_id, relative_id, specific_relation)
            SELECT 'I', now() at time zone 'utc', user, NEW.id, NEW.master_id, NEW.affiliate_id, NEW.relative_id, NEW.specific_relation;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 402 (class 1255 OID 570253)
-- Name: process_affiliates_history(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_affiliates_history() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF
            (TG_OP = 'DELETE') THEN
            INSERT INTO affiliates_history(operation, stamp, master_id, affiliate_id, relative_id, specific_relation)
            SELECT 'D',
                   now() at time zone 'utc',
                   OLD.master_id,
                   OLD.affiliate_id,
                   OLD.relative_id,
                   OLD.specific_relation;

            ELSIF
            (TG_OP = 'UPDATE' AND
                ((OLD.relative_id is not null and NEW.relative_id is not null and OLD.relative_id != NEW.relative_id)
                or
                (OLD.specific_relation is not null and NEW.specific_relation is not null and OLD.specific_relation != NEW.specific_relation)
                or
                ((OLD.relative_id is not null and NEW.relative_id is null) or (NEW.relative_id is not null and OLD.relative_id is null))
                or
                ((OLD.specific_relation is not null and NEW.specific_relation is null) or (NEW.specific_relation is not null and OLD.specific_relation is null))))
                THEN
            INSERT INTO affiliates_history(operation, stamp, master_id, affiliate_id, relative_id, specific_relation)
            SELECT 'U',
                   now() at time zone 'utc',
                   NEW.master_id,
                   NEW.affiliate_id,
                   NEW.relative_id,
                   NEW.specific_relation;
            ELSIF
            (TG_OP = 'INSERT') THEN
            INSERT INTO affiliates_history(operation, stamp, master_id, affiliate_id, relative_id, specific_relation)
            SELECT 'I',
                   now() at time zone 'utc',
                   NEW.master_id,
                   NEW.affiliate_id,
                   NEW.relative_id,
                   NEW.specific_relation;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 398 (class 1255 OID 569869)
-- Name: process_branch_audit(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_branch_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'DELETE') THEN
            INSERT INTO branch_audit(operation, stamp, userid, entity_id, name, ext_code, address, type_bits, workhours, timezone, remote, visible)
            SELECT 'D', now() at time zone 'utc', user, OLD.id, OLD.name, OLD.ext_code, OLD.address, OLD.type_bits, OLD.workhours, OLD.timezone, OLD.remote, OLD.visible;
            ELSIF (TG_OP = 'UPDATE') THEN
            INSERT INTO branch_audit(operation, stamp, userid, entity_id, name, ext_code, address, type_bits, workhours, timezone, remote, visible)
            SELECT 'U', now() at time zone 'utc', user, NEW.id, NEW.name, NEW.ext_code, NEW.address, NEW.type_bits, NEW.workhours, NEW.timezone, NEW.remote, NEW.visible;
            ELSIF (TG_OP = 'INSERT') THEN
            INSERT INTO branch_audit(operation, stamp, userid, entity_id, name, ext_code, address, type_bits, workhours, timezone, remote, visible)
            SELECT 'I', now() at time zone 'utc', user, NEW.id, NEW.name, NEW.ext_code, NEW.address, NEW.type_bits, NEW.workhours, NEW.timezone, NEW.remote, NEW.visible;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 388 (class 1255 OID 569797)
-- Name: process_customer_audit(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_customer_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
                BEGIN
                    IF (TG_OP = 'DELETE') THEN
                        INSERT INTO customer_audit(operation, stamp, userid, entity_id, mdm_id, first_name, last_name, middle_name, service_pack)
                        SELECT 'D', now() at time zone 'utc', user, OLD.id, OLD.mdm_id, old.first_name, old.last_name, old.middle_name, old.service_pack;
                    ELSIF (TG_OP = 'UPDATE') THEN
                        INSERT INTO customer_audit(operation, stamp, userid, entity_id, mdm_id, first_name, last_name, middle_name, service_pack)
                        SELECT 'U', now() at time zone 'utc', user, NEW.id, NEW.mdm_id, NEW.first_name, NEW.last_name, NEW.middle_name, NEW.service_pack;
                    ELSIF (TG_OP = 'INSERT') THEN
                        INSERT INTO customer_audit(operation, stamp, userid, entity_id, mdm_id, first_name, last_name, middle_name, service_pack)
                        SELECT 'I', now() at time zone 'utc', user, NEW.id, NEW.mdm_id, NEW.first_name, NEW.last_name, NEW.middle_name, NEW.service_pack;
                    END IF;
                    RETURN NULL; -- result is ignored since this is an AFTER trigger
                END;
            $$;


--
-- TOC entry 401 (class 1255 OID 569979)
-- Name: process_customer_card_access_audit(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_customer_card_access_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'DELETE') THEN
            INSERT INTO customer_card_access_audit(operation, stamp, userid, entity_id, customer_id, start_dt, end_dt, login, permanent, all_branches)
            SELECT 'D', now() at time zone 'utc', user, OLD.id, OLD.customer_id, OLD.start_dt, OLD.end_dt, OLD.login, OLD.permanent, OLD.all_branches;
            ELSIF (TG_OP = 'UPDATE') THEN
            INSERT INTO customer_card_access_audit(operation, stamp, userid, entity_id, customer_id, start_dt, end_dt, login, permanent, all_branches)
            SELECT 'U', now() at time zone 'utc', user, NEW.id, NEW.customer_id, NEW.start_dt, NEW.end_dt, NEW.login, NEW.permanent, NEW.all_branches;
            ELSIF (TG_OP = 'INSERT') THEN
            INSERT INTO customer_card_access_audit(operation, stamp, userid, entity_id, customer_id, start_dt, end_dt, login, permanent, all_branches)
            SELECT 'I', now() at time zone 'utc', user, NEW.id, NEW.customer_id, NEW.start_dt, NEW.end_dt, NEW.login, NEW.permanent, NEW.all_branches;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 399 (class 1255 OID 569805)
-- Name: process_customer_prime_audit(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_customer_prime_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'DELETE') THEN
            INSERT INTO customer_prime_audit(operation, stamp, userid, entity_id, customer_id, group_id, temp_group_exp_date, vip, top, vip_confirmed)
            SELECT 'D', now() at time zone 'utc', user, OLD.id, OLD.customer_id, OLD.group_id, OLD.temp_group_exp_date, OLD.vip, OLD.top, OLD.vip_confirmed;
            ELSIF (TG_OP = 'UPDATE') THEN
            INSERT INTO customer_prime_audit(operation, stamp, userid, entity_id, customer_id, group_id, temp_group_exp_date, vip, top, vip_confirmed)
            SELECT 'U', now() at time zone 'utc', user, NEW.id, NEW.customer_id, NEW.group_id, NEW.temp_group_exp_date, NEW.vip, NEW.top, NEW.vip_confirmed;
            ELSIF (TG_OP = 'INSERT') THEN
            INSERT INTO customer_prime_audit(operation, stamp, userid, entity_id, customer_id, group_id, temp_group_exp_date, vip, top, vip_confirmed)
            SELECT 'I', now() at time zone 'utc', user, NEW.id, NEW.customer_id, NEW.group_id, NEW.temp_group_exp_date, NEW.vip, NEW.top, NEW.vip_confirmed;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 403 (class 1255 OID 570358)
-- Name: process_customer_to_deleted_employee(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_customer_to_deleted_employee() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'DELETE') THEN
               IF (OLD.role_in_team = 'SUPERVISOR' OR OLD.role_in_team = 'SUPERVISOR_PRIME') THEN
                DELETE FROM customer_to_deleted_employee ctde where ctde.customer_id = OLD.customer_id;
            END IF;
            ELSIF (TG_OP = 'UPDATE') THEN
                IF (NEW.service_team_member_id IS NOT NULL AND NEW.service_team_member_id IS DISTINCT FROM OLD.service_team_member_id) THEN
                    IF (NEW.role_in_team = 'PERSONAL_MANAGER' OR NEW.role_in_team = 'PFM') THEN
                    DELETE FROM customer_to_deleted_employee ctde where ctde.customer_id = NEW.customer_id and ctde.role_in_team in ('PERSONAL_MANAGER', 'PFM');
                ELSIF (NEW.role_in_team = 'BILL_ACCOUNTANT' OR NEW.role_in_team = 'BILL_ACCOUNTANT_PRIVILEGE') THEN
                    DELETE FROM customer_to_deleted_employee ctde where ctde.customer_id = NEW.customer_id and ctde.role_in_team in ('BILL_ACCOUNTANT', 'BILL_ACCOUNTANT_PRIVILEGE');
            END IF;
            END IF;
            ELSIF (TG_OP = 'INSERT') THEN
                IF (NEW.service_team_member_id IS NOT NULL) THEN
                    IF (NEW.role_in_team = 'PERSONAL_MANAGER' OR NEW.role_in_team = 'PFM') THEN
                    DELETE FROM customer_to_deleted_employee ctde where ctde.customer_id = NEW.customer_id and ctde.role_in_team in ('PERSONAL_MANAGER', 'PFM');
                ELSIF (NEW.role_in_team = 'BILL_ACCOUNTANT' OR NEW.role_in_team = 'BILL_ACCOUNTANT_PRIVILEGE') THEN
                    DELETE FROM customer_to_deleted_employee ctde where ctde.customer_id = NEW.customer_id and ctde.role_in_team in ('BILL_ACCOUNTANT', 'BILL_ACCOUNTANT_PRIVILEGE');
            END IF;
            END IF;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 404 (class 1255 OID 569821)
-- Name: process_customer_to_employee_audit(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_customer_to_employee_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'DELETE') THEN
            INSERT INTO customer_to_employee_audit(operation, stamp, userid, entity_id, customer_id, service_team_member_id, role_in_team, branch_id, shifter_id, assigned_date)
            SELECT 'D', now() at time zone 'utc', user, OLD.id, OLD.customer_id, OLD.service_team_member_id, OLD.role_in_team, OLD.branch_id, OLD.shifter_id, OLD.assigned_date;
            ELSIF (TG_OP = 'UPDATE') THEN
            INSERT INTO customer_to_employee_audit(operation, stamp, userid, entity_id, customer_id, service_team_member_id, role_in_team, branch_id, shifter_id, assigned_date)
            SELECT 'U', now() at time zone 'utc', user, NEW.id, NEW.customer_id, NEW.service_team_member_id, NEW.role_in_team, NEW.branch_id, NEW.shifter_id, NEW.assigned_date;
            ELSIF (TG_OP = 'INSERT') THEN
            INSERT INTO customer_to_employee_audit(operation, stamp, userid, entity_id, customer_id, service_team_member_id, role_in_team, branch_id, shifter_id, assigned_date)
            SELECT 'I', now() at time zone 'utc', user, NEW.id, NEW.customer_id, NEW.service_team_member_id, NEW.role_in_team, NEW.branch_id, NEW.shifter_id, NEW.assigned_date;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 397 (class 1255 OID 569859)
-- Name: process_delayed_shift_audit(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_delayed_shift_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'DELETE') THEN
            INSERT INTO delayed_shift_audit(operation, stamp, userid, entity_id, customer_to_employee_id, shifter_employee_id, shift_date, permanent, return_date, shift_attempt_date, state_retry, reason)
            SELECT 'D', now() at time zone 'utc', user, OLD.id, OLD.customer_to_employee_id, OLD.shifter_employee_id, OLD.shift_date, OLD.permanent, OLD.return_date, OLD.shift_attempt_date, OLD.state_retry, OLD.reason;
            ELSIF (TG_OP = 'UPDATE') THEN
            INSERT INTO delayed_shift_audit(operation, stamp, userid, entity_id, customer_to_employee_id, shifter_employee_id, shift_date, permanent, return_date, shift_attempt_date, state_retry, reason)
            SELECT 'U', now() at time zone 'utc', user, NEW.id, OLD.customer_to_employee_id, OLD.shifter_employee_id, OLD.shift_date, OLD.permanent, OLD.return_date, OLD.shift_attempt_date, OLD.state_retry, OLD.reason;
            ELSIF (TG_OP = 'INSERT') THEN
            INSERT INTO delayed_shift_audit(operation, stamp, userid, entity_id, customer_to_employee_id, shifter_employee_id, shift_date, permanent, return_date, shift_attempt_date, state_retry, reason)
            SELECT 'I', now() at time zone 'utc', user, NEW.id, OLD.customer_to_employee_id, OLD.shifter_employee_id, OLD.shift_date, OLD.permanent, OLD.return_date, OLD.shift_attempt_date, OLD.state_retry, OLD.reason;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 396 (class 1255 OID 569849)
-- Name: process_employee_audit(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_employee_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'DELETE') THEN
            INSERT INTO employee_audit(operation, stamp, userid, entity_id, login, pers_num, last_name, first_name, middle_name, phone_num, work_phone_num, work_phone_ext, email)
            SELECT 'D', now() at time zone 'utc', user, OLD.id, OLD.login, OLD.pers_num, OLD.last_name, OLD.first_name, OLD.middle_name, OLD.phone_num, OLD.work_phone_num, OLD.work_phone_ext, OLD.email;
            ELSIF (TG_OP = 'UPDATE') THEN
            INSERT INTO employee_audit(operation, stamp, userid, entity_id, login, pers_num, last_name, first_name, middle_name, phone_num, work_phone_num, work_phone_ext, email)
            SELECT 'U', now() at time zone 'utc', user, NEW.id, NEW.login, NEW.pers_num, NEW.last_name, NEW.first_name, NEW.middle_name, NEW.phone_num, NEW.work_phone_num, NEW.work_phone_ext, NEW.email;
            ELSIF (TG_OP = 'INSERT') THEN
            INSERT INTO employee_audit(operation, stamp, userid, entity_id, login, pers_num, last_name, first_name, middle_name, phone_num, work_phone_num, work_phone_ext, email)
            SELECT 'I', now() at time zone 'utc', user, NEW.id, NEW.login, NEW.pers_num, NEW.last_name, NEW.first_name, NEW.middle_name, NEW.phone_num, NEW.work_phone_num, NEW.work_phone_ext, NEW.email;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 400 (class 1255 OID 569841)
-- Name: process_employee_to_branch_audit(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_employee_to_branch_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'DELETE') THEN
            INSERT INTO employee_to_branch_audit(operation, stamp, userid, entity_id, branch_id, employee_id, default_sv, department, failed_attempts, default_branch, next_actualization_at, role_bits, rst_group_id)
            SELECT 'D', now() at time zone 'utc', user, OLD.id, OLD.branch_id, OLD.employee_id, OLD.default_sv, OLD.department, OLD.failed_attempts, OLD.default_branch, OLD.next_actualization_at, OLD.role_bits, OLD.rst_group_id;
            ELSIF (TG_OP = 'UPDATE') THEN
            INSERT INTO employee_to_branch_audit(operation, stamp, userid, entity_id, branch_id, employee_id, default_sv, department, failed_attempts, default_branch, next_actualization_at, role_bits, rst_group_id)
            SELECT 'U', now() at time zone 'utc', user, NEW.id, NEW.branch_id, NEW.employee_id, NEW.default_sv, NEW.department, NEW.failed_attempts, NEW.default_branch, NEW.next_actualization_at, NEW.role_bits, NEW.rst_group_id;
            ELSIF (TG_OP = 'INSERT') THEN
            INSERT INTO employee_to_branch_audit(operation, stamp, userid, entity_id, branch_id, employee_id, default_sv, department, failed_attempts, default_branch, next_actualization_at, role_bits, rst_group_id)
            SELECT 'I', now() at time zone 'utc', user, NEW.id, NEW.branch_id, NEW.employee_id, NEW.default_sv, NEW.department, NEW.failed_attempts, NEW.default_branch, NEW.next_actualization_at, NEW.role_bits, NEW.rst_group_id;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 394 (class 1255 OID 569831)
-- Name: process_temporary_shift_audit(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.process_temporary_shift_audit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
            IF (TG_OP = 'DELETE') THEN
            INSERT INTO temporary_shift_audit(operation, stamp, userid, entity_id, customer_to_employee_id, return_employee_id, return_date, return_attempt_date, state_retry, start_date, reason)
            SELECT 'D', now() at time zone 'utc', user, OLD.id, OLD.customer_to_employee_id, OLD.return_employee_id, OLD.return_date, OLD.return_attempt_date, OLD.state_retry, OLD.start_date, OLD.reason;
            ELSIF (TG_OP = 'UPDATE') THEN
            INSERT INTO temporary_shift_audit(operation, stamp, userid, entity_id, customer_to_employee_id, return_employee_id, return_date, return_attempt_date, state_retry, start_date, reason)
            SELECT 'U', now() at time zone 'utc', user, NEW.id, NEW.customer_to_employee_id, NEW.return_employee_id, NEW.return_date, NEW.return_attempt_date, NEW.state_retry, NEW.start_date, NEW.reason;
            ELSIF (TG_OP = 'INSERT') THEN
            INSERT INTO temporary_shift_audit(operation, stamp, userid, entity_id, customer_to_employee_id, return_employee_id, return_date, return_attempt_date, state_retry, start_date, reason)
            SELECT 'I', now() at time zone 'utc', user, NEW.id, NEW.customer_to_employee_id, NEW.return_employee_id, NEW.return_date, NEW.return_attempt_date, NEW.state_retry, NEW.start_date, NEW.reason;
            END IF;
            RETURN NULL; -- result is ignored since this is an AFTER trigger
            END;
            $$;


--
-- TOC entry 391 (class 1255 OID 570482)
-- Name: trg_affiliates_insert_delete_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_affiliates_insert_delete_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            DECLARE
            v_customer_id bigint;
            BEGIN
                -- Определяем ID клиента в зависимости от операции
                IF (TG_OP = 'DELETE') THEN
                    v_customer_id := OLD.affiliate_id;
            ELSE
                    v_customer_id := NEW.affiliate_id;
            END IF;

                -- Вставляем запись в tsss_queue
            INSERT INTO tsss_queue(mdm_id, type, change_key)
            SELECT
                c.mdm_id,
                'VIP_TOP',
                build_vip_top_change_key(c.id)
            FROM customer c
            WHERE c.id = v_customer_id;

            RETURN NULL;
            END;
            $$;


--
-- TOC entry 392 (class 1255 OID 570484)
-- Name: trg_affiliates_update_relative_id_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_affiliates_update_relative_id_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                -- Проверяем, что изменилось значение поля relative_id
                IF OLD.relative_id IS DISTINCT FROM NEW.relative_id THEN
                    INSERT INTO tsss_queue(mdm_id, type, change_key)
            SELECT
                c.mdm_id,
                'VIP_TOP',
                build_vip_top_change_key(c.id)
            FROM customer c
            WHERE c.id = NEW.affiliate_id;
            END IF;

            RETURN NULL;
            END;
            $$;


--
-- TOC entry 411 (class 1255 OID 570470)
-- Name: trg_cte_insert_update_delete_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_cte_insert_update_delete_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            DECLARE
            v_customer_id BIGINT;
            BEGIN
                -- Определяем ID клиента в зависимости от события
                IF (TG_OP = 'DELETE') THEN
                    v_customer_id := OLD.customer_id;
                ELSE
                    v_customer_id := NEW.customer_id;
                END IF;

                ----------------------------------------------------------------------
                -- Вставляем текущее состояние команды клиента в tsss_queue
                ----------------------------------------------------------------------
                INSERT INTO tsss_queue(mdm_id, type, change_key)
                SELECT c.mdm_id,
                   'SERVICE_TEAM',
                    build_service_team_change_key(c.id)
                FROM customer c
                WHERE c.id = v_customer_id;

            RETURN NULL;
            END;
            $$;


--
-- TOC entry 409 (class 1255 OID 570466)
-- Name: trg_customer_delete_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_customer_delete_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                -- 1. SERVICE_TEAM
            INSERT INTO tsss_queue (mdm_id, type, change_key)
            VALUES (
                       OLD.mdm_id,
                       'SERVICE_TEAM',
                       '{"serviceGroup" : null, "productType" : "MULTICART", "team" : []}'
                   );

            -- 2. VIP_TOP
            INSERT INTO tsss_queue (mdm_id, type, change_key)
            VALUES (
                       OLD.mdm_id,
                       'VIP_TOP',
                       '{"vip" : false, "top" : false, "superVip" : false, "masterMdmId" : null, "relativeExtCode" : null}'
                   );

            RETURN OLD;
            END;
            $$;


--
-- TOC entry 412 (class 1255 OID 570472)
-- Name: trg_customer_prime_insert_delete_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_customer_prime_insert_delete_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            DECLARE
            v_customer_id bigint;
            BEGIN
                -- Определяем ID клиента в зависимости от операции
                IF (TG_OP = 'DELETE') THEN
                    v_customer_id := OLD.customer_id;
            ELSE
                    v_customer_id := NEW.customer_id;
            END IF;

            -- Вставляем запись в tsss_queue с VIP_TOP
            INSERT INTO tsss_queue(mdm_id, type, change_key)
            SELECT
                c.mdm_id,
                'VIP_TOP',
                build_vip_top_change_key(c.id)
            FROM customer c
            WHERE c.id = v_customer_id;

            -- Вставляем запись в tsss_queue с SERVICE_TEAM
            INSERT INTO tsss_queue(mdm_id, type, change_key)
            SELECT
                c.mdm_id,
                'SERVICE_TEAM',
                build_service_team_change_key(c.id)
            FROM customer c
            WHERE c.id = v_customer_id;

            RETURN NULL;
            END;
            $$;


--
-- TOC entry 389 (class 1255 OID 570476)
-- Name: trg_customer_prime_update_group_id_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_customer_prime_update_group_id_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                -- Проверяем, что изменилось значение
                IF OLD.group_id IS DISTINCT FROM NEW.group_id THEN
                    ----------------------------------------------------------------------
                    -- Вставляем текущее состояние команды клиента в tsss_queue
                    ----------------------------------------------------------------------
                    INSERT INTO tsss_queue(mdm_id, type, change_key)
                    SELECT c.mdm_id,
                        'SERVICE_TEAM',
                        build_service_team_change_key(c.id)
                    FROM customer c
                    WHERE c.id = NEW.customer_id;
                END IF;

            RETURN NULL;
            END;
            $$;


--
-- TOC entry 413 (class 1255 OID 570474)
-- Name: trg_customer_prime_update_vip_top_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_customer_prime_update_vip_top_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                -- Проверяем, что изменилось хотя бы одно из полей vip или top
                IF (OLD.vip IS DISTINCT FROM NEW.vip OR OLD.top IS DISTINCT FROM NEW.top) THEN
                    INSERT INTO tsss_queue(mdm_id, type, change_key)
                    SELECT c.mdm_id, 'VIP_TOP', build_vip_top_change_key(c.id)
                    FROM customer c
                    WHERE c.id = NEW.customer_id;
                END IF;

            RETURN NULL;
            END;
            $$;


--
-- TOC entry 410 (class 1255 OID 570468)
-- Name: trg_customer_update_mdm_id_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_customer_update_mdm_id_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                -- Сначала проверим, действительно ли изменился mdm_id
                IF NEW.mdm_id IS DISTINCT FROM OLD.mdm_id THEN

                -------------------------------------------------------------------
                -- 1. Добавляем записи для старого mdm_id (сброс команд и VIP)
                -------------------------------------------------------------------
                INSERT INTO tsss_queue (mdm_id, type, change_key)
                VALUES (
                    OLD.mdm_id,
                    'SERVICE_TEAM',
                    '{"serviceGroup" : null, "productType" : "MULTICART", "team" : []}'
                );

                INSERT INTO tsss_queue (mdm_id, type, change_key)
                VALUES (
                           OLD.mdm_id,
                           'VIP_TOP',
                           '{"vip" : false, "top" : false, "superVip" : false, "masterMdmId" : null, "relativeExtCode" : null}'
                       );

                -------------------------------------------------------------------
                -- 2. Добавляем записи для НОВОГО mdm_id
                -------------------------------------------------------------------
                -- SERVICE_TEAM
                INSERT INTO tsss_queue (mdm_id, type, change_key)
                SELECT c.mdm_id, 'SERVICE_TEAM', build_service_team_change_key(c.id)
                FROM customer c
                WHERE c.id = NEW.id;

                -- VIP_TOP
                INSERT INTO tsss_queue (mdm_id, type, change_key)
                SELECT c.mdm_id, 'VIP_TOP', build_vip_top_change_key(c.id)
                FROM customer c
                WHERE c.id = NEW.id;
            END IF;

            RETURN NEW;
            END;
            $$;


--
-- TOC entry 405 (class 1255 OID 813154)
-- Name: trg_set_customer_default_service_pack(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_set_customer_default_service_pack() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                IF NEW.service_pack IS NULL THEN
                    NEW.service_pack := 'Не определено';
                END IF;
            RETURN NEW;
            END;
            $$;


--
-- TOC entry 387 (class 1255 OID 570478)
-- Name: trg_svh_insert_delete_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_svh_insert_delete_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            DECLARE
            v_customer_id bigint;
            BEGIN
                -- Определяем ID клиента в зависимости от операции
                IF (TG_OP = 'DELETE') THEN
                    v_customer_id := OLD.customer_id;
                ELSE
                    v_customer_id := NEW.customer_id;
                END IF;

                -- Вставляем запись в tsss_queue
                INSERT INTO tsss_queue(mdm_id, type, change_key)
                SELECT
                    c.mdm_id,
                    'VIP_TOP',
                    build_vip_top_change_key(c.id)
                FROM customer c
                WHERE c.id = v_customer_id;

            RETURN NULL;
            END;
            $$;


--
-- TOC entry 390 (class 1255 OID 570480)
-- Name: trg_svh_update_super_vip_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_svh_update_super_vip_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                -- Проверяем, что изменилось значение поля super_vip
                IF OLD.super_vip IS DISTINCT FROM NEW.super_vip THEN
                    INSERT INTO tsss_queue(mdm_id, type, change_key)
                    SELECT
                        c.mdm_id,
                        'VIP_TOP',
                        build_vip_top_change_key(c.id)
                    FROM customer c
                    WHERE c.id = NEW.customer_id;
                END IF;

            RETURN NULL;
            END;
            $$;


--
-- TOC entry 415 (class 1255 OID 570494)
-- Name: trg_temporary_shift_insert_tsss_queue(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_temporary_shift_insert_tsss_queue() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            DECLARE
                v_customer_id BIGINT;
            BEGIN
                v_customer_id := (select cte.customer_id from customer_to_employee cte where cte.id = NEW.customer_to_employee_id);
            ----------------------------------------------------------------------
            -- Вставляем текущее состояние команды клиента в tsss_queue
            ----------------------------------------------------------------------
            INSERT INTO tsss_queue(mdm_id, type, change_key)
            SELECT c.mdm_id,
                'SERVICE_TEAM',
                build_service_team_change_key(c.id)
            FROM customer c
            WHERE c.id = v_customer_id;

            RETURN NULL;
            END;
            $$;


--
-- TOC entry 393 (class 1255 OID 570486)
-- Name: trg_tsss_queue_check_last(); Type: FUNCTION; Schema: sofk_application; Owner: -
--

CREATE FUNCTION sofk_application.trg_tsss_queue_check_last() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            DECLARE
            last_key varchar(2024);
            BEGIN
                -- Получаем change_key последней записи с тем же type
            SELECT change_key
            INTO last_key
            FROM tsss_queue
            WHERE mdm_id = NEW.mdm_id
              AND type = NEW.type
            ORDER BY id DESC
                LIMIT 1;

            -- Если последняя запись существует и change_key совпадает — пропускаем вставку
            IF last_key IS NOT NULL AND last_key = NEW.change_key THEN
                    RETURN NULL; -- пропускаем вставку
            ELSE
                    RETURN NEW;  -- вставляем запись
            END IF;
            END;
            $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- TOC entry 364 (class 1259 OID 804207)
-- Name: hb_table; Type: TABLE; Schema: hb_debezium; Owner: -
--

CREATE TABLE hb_debezium.hb_table (
    id numeric
);


--
-- TOC entry 366 (class 1259 OID 914766)
-- Name: affiliate_invitation; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.affiliate_invitation (
    id bigint NOT NULL,
    aff_inv_id bigint NOT NULL,
    master_id bigint NOT NULL,
    affiliate_id bigint NOT NULL,
    relative_id integer,
    create_dt timestamp without time zone DEFAULT now() NOT NULL,
    status character varying(30) NOT NULL,
    last_change_dt timestamp without time zone,
    approved boolean,
    reject_reason character varying(255)
);


--
-- TOC entry 4111 (class 0 OID 0)
-- Dependencies: 366
-- Name: TABLE affiliate_invitation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.affiliate_invitation IS 'Таблица для работы с приглашениями в Близкий круг';


--
-- TOC entry 4112 (class 0 OID 0)
-- Dependencies: 366
-- Name: COLUMN affiliate_invitation.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliate_invitation.id IS 'Идентификатор записи';


--
-- TOC entry 4113 (class 0 OID 0)
-- Dependencies: 366
-- Name: COLUMN affiliate_invitation.aff_inv_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliate_invitation.aff_inv_id IS 'Идентификатор приглашения из tbcv-vip-prime-spo-aff.affiliate_invitation.id';


--
-- TOC entry 4114 (class 0 OID 0)
-- Dependencies: 366
-- Name: COLUMN affiliate_invitation.master_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliate_invitation.master_id IS 'Идентификатор ключевой персоны';


--
-- TOC entry 4115 (class 0 OID 0)
-- Dependencies: 366
-- Name: COLUMN affiliate_invitation.affiliate_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliate_invitation.affiliate_id IS 'Идентификатор аффилированного лица';


--
-- TOC entry 4116 (class 0 OID 0)
-- Dependencies: 366
-- Name: COLUMN affiliate_invitation.relative_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliate_invitation.relative_id IS 'Идентификатор категории родства';


--
-- TOC entry 4117 (class 0 OID 0)
-- Dependencies: 366
-- Name: COLUMN affiliate_invitation.create_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliate_invitation.create_dt IS 'Дата и время создания записи';


--
-- TOC entry 4118 (class 0 OID 0)
-- Dependencies: 366
-- Name: COLUMN affiliate_invitation.status; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliate_invitation.status IS 'Статус создания приглашения Семейными';


--
-- TOC entry 4119 (class 0 OID 0)
-- Dependencies: 366
-- Name: COLUMN affiliate_invitation.last_change_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliate_invitation.last_change_dt IS 'Дата и время последнего изменения приглашения (по данным из PersonPub)';


--
-- TOC entry 4120 (class 0 OID 0)
-- Dependencies: 366
-- Name: COLUMN affiliate_invitation.approved; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliate_invitation.approved IS 'Выбранное решение по приглашению';


--
-- TOC entry 4121 (class 0 OID 0)
-- Dependencies: 366
-- Name: COLUMN affiliate_invitation.reject_reason; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliate_invitation.reject_reason IS 'Причина проставляения метки false при подвтерждении приглашения на базовых условиях';


--
-- TOC entry 365 (class 1259 OID 914765)
-- Name: affiliate_invitation_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.affiliate_invitation ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.affiliate_invitation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 251 (class 1259 OID 569687)
-- Name: affiliates; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.affiliates (
    id bigint NOT NULL,
    master_id bigint NOT NULL,
    affiliate_id bigint NOT NULL,
    relative_id bigint,
    specific_relation character varying(25),
    approved boolean,
    end_dt timestamp without time zone,
    added_vtbo boolean DEFAULT false NOT NULL
);


--
-- TOC entry 4122 (class 0 OID 0)
-- Dependencies: 251
-- Name: TABLE affiliates; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.affiliates IS 'Аффилированные лица';


--
-- TOC entry 4123 (class 0 OID 0)
-- Dependencies: 251
-- Name: COLUMN affiliates.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates.id IS 'Идентификатор';


--
-- TOC entry 4124 (class 0 OID 0)
-- Dependencies: 251
-- Name: COLUMN affiliates.master_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates.master_id IS 'Ссылка на основного клиента';


--
-- TOC entry 4125 (class 0 OID 0)
-- Dependencies: 251
-- Name: COLUMN affiliates.affiliate_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates.affiliate_id IS 'Ссылка на аффилированное лицо';


--
-- TOC entry 4126 (class 0 OID 0)
-- Dependencies: 251
-- Name: COLUMN affiliates.relative_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates.relative_id IS 'Идентификатор семейного родства аффилированного лица';


--
-- TOC entry 4127 (class 0 OID 0)
-- Dependencies: 251
-- Name: COLUMN affiliates.specific_relation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates.specific_relation IS 'Другое наименование семейного родства аффилированного лица';


--
-- TOC entry 4128 (class 0 OID 0)
-- Dependencies: 251
-- Name: COLUMN affiliates.approved; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates.approved IS 'Статус подтверждение аффилированного лица true- аф.лицо подтверждено, false- аф.лицо не подтвержденое';


--
-- TOC entry 4129 (class 0 OID 0)
-- Dependencies: 251
-- Name: COLUMN affiliates.end_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates.end_dt IS 'Дата и время окончания действия связки ключевая персона - аффилированное лицо';


--
-- TOC entry 4130 (class 0 OID 0)
-- Dependencies: 251
-- Name: COLUMN affiliates.added_vtbo; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates.added_vtbo IS 'Канал добавления в Близкий круг: true - ВТБО, false - ВТБ Про';


--
-- TOC entry 267 (class 1259 OID 569808)
-- Name: affiliates_audit; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.affiliates_audit (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    userid character varying(64) NOT NULL,
    entity_id bigint NOT NULL,
    master_id bigint,
    affiliate_id bigint,
    relative_id bigint,
    specific_relation character varying(25)
);


--
-- TOC entry 4131 (class 0 OID 0)
-- Dependencies: 267
-- Name: TABLE affiliates_audit; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.affiliates_audit IS 'История изменений данных в таблице affiliates';


--
-- TOC entry 4132 (class 0 OID 0)
-- Dependencies: 267
-- Name: COLUMN affiliates_audit.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_audit.id IS 'Идентификатор';


--
-- TOC entry 4133 (class 0 OID 0)
-- Dependencies: 267
-- Name: COLUMN affiliates_audit.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_audit.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4134 (class 0 OID 0)
-- Dependencies: 267
-- Name: COLUMN affiliates_audit.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_audit.stamp IS 'Дата и время изменения';


--
-- TOC entry 4135 (class 0 OID 0)
-- Dependencies: 267
-- Name: COLUMN affiliates_audit.userid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_audit.userid IS 'Новое значение';


--
-- TOC entry 4136 (class 0 OID 0)
-- Dependencies: 267
-- Name: COLUMN affiliates_audit.entity_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_audit.entity_id IS 'Идентификатор изменившейся записи';


--
-- TOC entry 4137 (class 0 OID 0)
-- Dependencies: 267
-- Name: COLUMN affiliates_audit.master_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_audit.master_id IS 'Ссылка на основного клиента';


--
-- TOC entry 4138 (class 0 OID 0)
-- Dependencies: 267
-- Name: COLUMN affiliates_audit.affiliate_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_audit.affiliate_id IS 'Ссылка на аффилированное лицо';


--
-- TOC entry 4139 (class 0 OID 0)
-- Dependencies: 267
-- Name: COLUMN affiliates_audit.relative_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_audit.relative_id IS 'Идентификатор семейного родства аффилированного лица';


--
-- TOC entry 4140 (class 0 OID 0)
-- Dependencies: 267
-- Name: COLUMN affiliates_audit.specific_relation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_audit.specific_relation IS 'Другое наименование семейного родства аффилированного лица';


--
-- TOC entry 266 (class 1259 OID 569807)
-- Name: affiliates_audit_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.affiliates_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.affiliates_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 335 (class 1259 OID 570248)
-- Name: affiliates_history; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.affiliates_history (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    master_id bigint NOT NULL,
    affiliate_id bigint NOT NULL,
    relative_id bigint,
    specific_relation character varying(256)
);


--
-- TOC entry 4141 (class 0 OID 0)
-- Dependencies: 335
-- Name: TABLE affiliates_history; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.affiliates_history IS 'История таблицы affiliates';


--
-- TOC entry 4142 (class 0 OID 0)
-- Dependencies: 335
-- Name: COLUMN affiliates_history.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_history.id IS 'Идентификатор';


--
-- TOC entry 4143 (class 0 OID 0)
-- Dependencies: 335
-- Name: COLUMN affiliates_history.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_history.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4144 (class 0 OID 0)
-- Dependencies: 335
-- Name: COLUMN affiliates_history.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_history.stamp IS 'Дата и время изменения';


--
-- TOC entry 4145 (class 0 OID 0)
-- Dependencies: 335
-- Name: COLUMN affiliates_history.master_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_history.master_id IS 'Ссылка на основного клиента';


--
-- TOC entry 4146 (class 0 OID 0)
-- Dependencies: 335
-- Name: COLUMN affiliates_history.affiliate_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_history.affiliate_id IS 'Ссылка на аффилированное лицо';


--
-- TOC entry 4147 (class 0 OID 0)
-- Dependencies: 335
-- Name: COLUMN affiliates_history.relative_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_history.relative_id IS 'Идентификатор категории родства';


--
-- TOC entry 4148 (class 0 OID 0)
-- Dependencies: 335
-- Name: COLUMN affiliates_history.specific_relation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.affiliates_history.specific_relation IS 'Другое название категории родства';


--
-- TOC entry 334 (class 1259 OID 570247)
-- Name: affiliates_history_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.affiliates_history ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.affiliates_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 250 (class 1259 OID 569686)
-- Name: affiliates_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.affiliates ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.affiliates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 229 (class 1259 OID 569447)
-- Name: branch; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.branch (
    id integer NOT NULL,
    name character varying(100),
    ext_code character varying(50) NOT NULL,
    address character varying(255),
    workhours character varying(100),
    timezone character varying(10),
    remote boolean,
    visible boolean,
    type_bits integer DEFAULT 0 NOT NULL,
    branch_segment character varying(50),
    city_id bigint,
    removed boolean DEFAULT false NOT NULL,
    change_dt_removed timestamp without time zone
);


--
-- TOC entry 4149 (class 0 OID 0)
-- Dependencies: 229
-- Name: TABLE branch; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.branch IS 'Отделения';


--
-- TOC entry 4150 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.id IS 'Идентификатор';


--
-- TOC entry 4151 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.name IS 'Наименование отделения';


--
-- TOC entry 4152 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.ext_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.ext_code IS 'Внешний идентификатор отделения';


--
-- TOC entry 4153 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.address; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.address IS 'Адрес отделения';


--
-- TOC entry 4154 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.remote; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.remote IS 'Отделение дистанционного обслуживания';


--
-- TOC entry 4155 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.visible; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.visible IS 'Видимость отделения для списка ТП';


--
-- TOC entry 4156 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.type_bits; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.type_bits IS 'Типы отделения';


--
-- TOC entry 4157 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.branch_segment; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.branch_segment IS 'Справочный тип ТП: Привилегия, Прайм, Смешанная (Привилегия + Прайм). РБ не проставляем - вычислять будем (не все РБ ТП в ДБ у нас).';


--
-- TOC entry 4158 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.city_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.city_id IS 'Ссылка на справочник городов';


--
-- TOC entry 4159 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.removed; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.removed IS 'Признак удаления ТП';


--
-- TOC entry 4160 (class 0 OID 0)
-- Dependencies: 229
-- Name: COLUMN branch.change_dt_removed; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch.change_dt_removed IS 'Дата проставления Признака удаления ТП (значения removed=true)';


--
-- TOC entry 279 (class 1259 OID 569862)
-- Name: branch_audit; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.branch_audit (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    userid character varying(64) NOT NULL,
    entity_id bigint NOT NULL,
    name character varying(100),
    ext_code character varying(50),
    address character varying(255),
    type_bits integer,
    workhours character varying(100),
    timezone character varying(10),
    remote boolean,
    visible boolean
);


--
-- TOC entry 4161 (class 0 OID 0)
-- Dependencies: 279
-- Name: TABLE branch_audit; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.branch_audit IS 'История изменений данных в таблице branch';


--
-- TOC entry 4162 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.id IS 'Идентификатор';


--
-- TOC entry 4163 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4164 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.stamp IS 'Дата и время изменения';


--
-- TOC entry 4165 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.userid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.userid IS 'Новое значение';


--
-- TOC entry 4166 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.entity_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.entity_id IS 'Идентификатор изменившейся записи';


--
-- TOC entry 4167 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.name IS 'Наименование отделения';


--
-- TOC entry 4168 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.ext_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.ext_code IS 'Внешний идентификатор отделения';


--
-- TOC entry 4169 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.address; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.address IS 'Адрес отделения';


--
-- TOC entry 4170 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.type_bits; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.type_bits IS 'Типы отделения';


--
-- TOC entry 4171 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.remote; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.remote IS 'Отделение дистанционного обслуживания';


--
-- TOC entry 4172 (class 0 OID 0)
-- Dependencies: 279
-- Name: COLUMN branch_audit.visible; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.branch_audit.visible IS 'Видимость отделения для списка ТП';


--
-- TOC entry 278 (class 1259 OID 569861)
-- Name: branch_audit_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.branch_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.branch_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 228 (class 1259 OID 569446)
-- Name: branch_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.branch ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.branch_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 303 (class 1259 OID 570011)
-- Name: city; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.city (
    id integer NOT NULL,
    name character varying(100) NOT NULL
);


--
-- TOC entry 4173 (class 0 OID 0)
-- Dependencies: 303
-- Name: TABLE city; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.city IS 'Справочник городов';


--
-- TOC entry 4174 (class 0 OID 0)
-- Dependencies: 303
-- Name: COLUMN city.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.city.id IS 'Идентификатор';


--
-- TOC entry 4175 (class 0 OID 0)
-- Dependencies: 303
-- Name: COLUMN city.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.city.name IS 'Название города';


--
-- TOC entry 302 (class 1259 OID 570010)
-- Name: city_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.city ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.city_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 325 (class 1259 OID 570194)
-- Name: company; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.company (
    id bigint NOT NULL,
    inn character varying(12) NOT NULL,
    name character varying(512) NOT NULL,
    client_type_id bigint NOT NULL,
    has_salary_project boolean NOT NULL,
    segment character varying(255)
);


--
-- TOC entry 4176 (class 0 OID 0)
-- Dependencies: 325
-- Name: TABLE company; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.company IS 'Информация о компаниях';


--
-- TOC entry 4177 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN company.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company.id IS 'Идентификатор';


--
-- TOC entry 4178 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN company.inn; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company.inn IS 'ИНН организации';


--
-- TOC entry 4179 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN company.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company.name IS 'Название компании';


--
-- TOC entry 4180 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN company.client_type_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company.client_type_id IS 'ext_code типа клиента в банке';


--
-- TOC entry 4181 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN company.has_salary_project; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company.has_salary_project IS 'Наличие зарплатного проекта';


--
-- TOC entry 4182 (class 0 OID 0)
-- Dependencies: 325
-- Name: COLUMN company.segment; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company.segment IS 'Сегмент организации';


--
-- TOC entry 324 (class 1259 OID 570193)
-- Name: company_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.company ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.company_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 333 (class 1259 OID 570235)
-- Name: company_kind_of_activity; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.company_kind_of_activity (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    ext_code bigint NOT NULL
);


--
-- TOC entry 4183 (class 0 OID 0)
-- Dependencies: 333
-- Name: TABLE company_kind_of_activity; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.company_kind_of_activity IS 'Справочник вид деятельности компании';


--
-- TOC entry 4184 (class 0 OID 0)
-- Dependencies: 333
-- Name: COLUMN company_kind_of_activity.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_kind_of_activity.id IS 'Идентификатор';


--
-- TOC entry 4185 (class 0 OID 0)
-- Dependencies: 333
-- Name: COLUMN company_kind_of_activity.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_kind_of_activity.name IS 'Расшифровка справочного значения';


--
-- TOC entry 4186 (class 0 OID 0)
-- Dependencies: 333
-- Name: COLUMN company_kind_of_activity.ext_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_kind_of_activity.ext_code IS 'Внешний идентификатор';


--
-- TOC entry 332 (class 1259 OID 570234)
-- Name: company_kind_of_activity_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.company_kind_of_activity ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.company_kind_of_activity_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 355 (class 1259 OID 570378)
-- Name: company_lead; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.company_lead (
    id bigint NOT NULL,
    lead_id bigint NOT NULL,
    status_code character varying(255) NOT NULL,
    product_name character varying(255) NOT NULL,
    appointed_branch_ext_code character varying(50),
    company_inn character varying(12) NOT NULL,
    company_name character varying(512) NOT NULL,
    creation_date timestamp without time zone NOT NULL,
    close_date timestamp without time zone,
    creator_employee_pers_num character varying(50) NOT NULL,
    appointed_employee_pers_num character varying(50)
);


--
-- TOC entry 4187 (class 0 OID 0)
-- Dependencies: 355
-- Name: TABLE company_lead; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.company_lead IS 'Перечень созданных лидов';


--
-- TOC entry 4188 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.id IS 'Идентификатор записи';


--
-- TOC entry 4189 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.lead_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.lead_id IS 'Идентификатор лида';


--
-- TOC entry 4190 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.status_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.status_code IS 'Код статус лида';


--
-- TOC entry 4191 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.product_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.product_name IS 'Название продукта по которому создан лид';


--
-- TOC entry 4192 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.appointed_branch_ext_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.appointed_branch_ext_code IS 'Код бисквит ТП, в которой обслуживается лид(поле ext_code из таблицы company_lead_branch)';


--
-- TOC entry 4193 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.company_inn; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.company_inn IS 'ИНН организации(поле inn из таблицы company)';


--
-- TOC entry 4194 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.company_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.company_name IS 'Наименование организации';


--
-- TOC entry 4195 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.creation_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.creation_date IS 'Дата создания лида';


--
-- TOC entry 4196 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.close_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.close_date IS 'Дата закрытия лида';


--
-- TOC entry 4197 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.creator_employee_pers_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.creator_employee_pers_num IS 'Табельный номер сотрудника создавший лид';


--
-- TOC entry 4198 (class 0 OID 0)
-- Dependencies: 355
-- Name: COLUMN company_lead.appointed_employee_pers_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead.appointed_employee_pers_num IS 'Табельный номер сотрудника обслуживающий лид';


--
-- TOC entry 357 (class 1259 OID 570386)
-- Name: company_lead_archive; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.company_lead_archive (
    id bigint NOT NULL,
    lead_id bigint NOT NULL,
    status_code character varying(255) NOT NULL,
    product_name character varying(255) NOT NULL,
    appointed_branch_ext_code character varying(50),
    company_inn character varying(12) NOT NULL,
    company_name character varying(512) NOT NULL,
    creation_date timestamp without time zone NOT NULL,
    close_date timestamp without time zone,
    creator_employee_pers_num character varying(50) NOT NULL,
    appointed_employee_pers_num character varying(50)
);


--
-- TOC entry 4199 (class 0 OID 0)
-- Dependencies: 357
-- Name: TABLE company_lead_archive; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.company_lead_archive IS 'Архивная таблица лидов';


--
-- TOC entry 4200 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.id IS 'Идентификатор записи';


--
-- TOC entry 4201 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.lead_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.lead_id IS 'Идентификатор лида';


--
-- TOC entry 4202 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.status_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.status_code IS 'Код статус лида';


--
-- TOC entry 4203 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.product_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.product_name IS 'Название продукта по которому создан лид';


--
-- TOC entry 4204 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.appointed_branch_ext_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.appointed_branch_ext_code IS 'Код бисквит ТП, в которой обслуживается лид(поле ext_code из таблицы company_lead_branch)';


--
-- TOC entry 4205 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.company_inn; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.company_inn IS 'ИНН организации(поле inn из таблицы company)';


--
-- TOC entry 4206 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.company_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.company_name IS 'Наименование организации';


--
-- TOC entry 4207 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.creation_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.creation_date IS 'Дата создания лида';


--
-- TOC entry 4208 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.close_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.close_date IS 'Дата закрытия лида';


--
-- TOC entry 4209 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.creator_employee_pers_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.creator_employee_pers_num IS 'Табельный номер сотрудника создавший лид';


--
-- TOC entry 4210 (class 0 OID 0)
-- Dependencies: 357
-- Name: COLUMN company_lead_archive.appointed_employee_pers_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_archive.appointed_employee_pers_num IS 'Табельный номер сотрудника обслуживающий лид';


--
-- TOC entry 356 (class 1259 OID 570385)
-- Name: company_lead_archive_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.company_lead_archive ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.company_lead_archive_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 353 (class 1259 OID 570372)
-- Name: company_lead_branch; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.company_lead_branch (
    id bigint NOT NULL,
    ext_code character varying(50) NOT NULL,
    name character varying(255) NOT NULL
);


--
-- TOC entry 4211 (class 0 OID 0)
-- Dependencies: 353
-- Name: TABLE company_lead_branch; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.company_lead_branch IS 'Справочник всех точек продаж';


--
-- TOC entry 4212 (class 0 OID 0)
-- Dependencies: 353
-- Name: COLUMN company_lead_branch.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_branch.id IS 'Идентификатор записи';


--
-- TOC entry 4213 (class 0 OID 0)
-- Dependencies: 353
-- Name: COLUMN company_lead_branch.ext_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_branch.ext_code IS 'Внешний идентификатор ТП';


--
-- TOC entry 4214 (class 0 OID 0)
-- Dependencies: 353
-- Name: COLUMN company_lead_branch.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_branch.name IS 'Название ТП';


--
-- TOC entry 352 (class 1259 OID 570371)
-- Name: company_lead_branch_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.company_lead_branch ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.company_lead_branch_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 354 (class 1259 OID 570377)
-- Name: company_lead_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.company_lead ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.company_lead_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 351 (class 1259 OID 570364)
-- Name: company_lead_status; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.company_lead_status (
    id bigint NOT NULL,
    code character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    is_final boolean NOT NULL
);


--
-- TOC entry 4215 (class 0 OID 0)
-- Dependencies: 351
-- Name: TABLE company_lead_status; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.company_lead_status IS 'Статус лида';


--
-- TOC entry 4216 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN company_lead_status.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_status.id IS 'Идентификатор записи';


--
-- TOC entry 4217 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN company_lead_status.code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_status.code IS 'Код статуса';


--
-- TOC entry 4218 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN company_lead_status.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_status.name IS 'Название статуса';


--
-- TOC entry 4219 (class 0 OID 0)
-- Dependencies: 351
-- Name: COLUMN company_lead_status.is_final; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_lead_status.is_final IS 'Является ли статус финальным';


--
-- TOC entry 350 (class 1259 OID 570363)
-- Name: company_lead_status_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.company_lead_status ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.company_lead_status_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 331 (class 1259 OID 570228)
-- Name: company_segment; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.company_segment (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    ext_code bigint NOT NULL
);


--
-- TOC entry 4220 (class 0 OID 0)
-- Dependencies: 331
-- Name: TABLE company_segment; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.company_segment IS 'Справочник сегмент компании';


--
-- TOC entry 4221 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN company_segment.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_segment.id IS 'Идентификатор';


--
-- TOC entry 4222 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN company_segment.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_segment.name IS 'Расшифровка справочного значения';


--
-- TOC entry 4223 (class 0 OID 0)
-- Dependencies: 331
-- Name: COLUMN company_segment.ext_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_segment.ext_code IS 'Внешний идентификатор';


--
-- TOC entry 330 (class 1259 OID 570227)
-- Name: company_segment_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.company_segment ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.company_segment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 329 (class 1259 OID 570221)
-- Name: company_type; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.company_type (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    ext_code bigint NOT NULL
);


--
-- TOC entry 4224 (class 0 OID 0)
-- Dependencies: 329
-- Name: TABLE company_type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.company_type IS 'Справочник тип компании';


--
-- TOC entry 4225 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN company_type.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_type.id IS 'Идентификатор';


--
-- TOC entry 4226 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN company_type.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_type.name IS 'Расшифровка справочного значения';


--
-- TOC entry 4227 (class 0 OID 0)
-- Dependencies: 329
-- Name: COLUMN company_type.ext_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.company_type.ext_code IS 'Внешний идентификатор';


--
-- TOC entry 328 (class 1259 OID 570220)
-- Name: company_type_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.company_type ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.company_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 221 (class 1259 OID 569400)
-- Name: customer; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer (
    id bigint NOT NULL,
    mdm_id character varying(256) NOT NULL,
    first_name character varying(50),
    last_name character varying(50),
    middle_name character varying(50),
    service_pack character varying(50),
    ex_ob boolean,
    fio character varying(160) GENERATED ALWAYS AS ((((lower((last_name)::text) || ' '::text) || lower((first_name)::text)) ||
CASE
    WHEN (middle_name IS NOT NULL) THEN (' '::text || lower((middle_name)::text))
    ELSE ''::text
END)) STORED,
    aum numeric(20,2) DEFAULT 0 NOT NULL,
    general_balance numeric(20,2) DEFAULT 0 NOT NULL,
    partner_balance numeric(20,2) DEFAULT 0 NOT NULL,
    investment_balance numeric(20,2) DEFAULT 0 NOT NULL
);


--
-- TOC entry 4228 (class 0 OID 0)
-- Dependencies: 221
-- Name: TABLE customer; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer IS 'Клиенты';


--
-- TOC entry 4229 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.id IS 'Идентификатор клиента';


--
-- TOC entry 4230 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.mdm_id IS 'MDM ID клиента';


--
-- TOC entry 4231 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.first_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.first_name IS 'Имя клиента';


--
-- TOC entry 4232 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.last_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.last_name IS 'Фамилия клиента';


--
-- TOC entry 4233 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.middle_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.middle_name IS 'Отчество клиента';


--
-- TOC entry 4234 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.service_pack; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.service_pack IS 'Пакет услуг';


--
-- TOC entry 4235 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.ex_ob; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.ex_ob IS 'Признак того, что клиент был мигрирован из открытия брокер';


--
-- TOC entry 4236 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.aum; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.aum IS 'АУМ клиента';


--
-- TOC entry 4237 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.general_balance; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.general_balance IS 'Общебанковские остатки клиента';


--
-- TOC entry 4238 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.partner_balance; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.partner_balance IS 'Партнерские остатки клиента';


--
-- TOC entry 4239 (class 0 OID 0)
-- Dependencies: 221
-- Name: COLUMN customer.investment_balance; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer.investment_balance IS 'Инвестиционные остатки клиента';


--
-- TOC entry 263 (class 1259 OID 569790)
-- Name: customer_audit; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_audit (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    userid character varying(64) NOT NULL,
    entity_id bigint NOT NULL,
    mdm_id character varying(256),
    last_name character varying(50),
    first_name character varying(50),
    middle_name character varying(50),
    service_pack character varying(50)
);


--
-- TOC entry 4240 (class 0 OID 0)
-- Dependencies: 263
-- Name: TABLE customer_audit; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_audit IS 'История изменений данных в таблице customer';


--
-- TOC entry 4241 (class 0 OID 0)
-- Dependencies: 263
-- Name: COLUMN customer_audit.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_audit.id IS 'Идентификатор';


--
-- TOC entry 4242 (class 0 OID 0)
-- Dependencies: 263
-- Name: COLUMN customer_audit.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_audit.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4243 (class 0 OID 0)
-- Dependencies: 263
-- Name: COLUMN customer_audit.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_audit.stamp IS 'Дата и время изменения';


--
-- TOC entry 4244 (class 0 OID 0)
-- Dependencies: 263
-- Name: COLUMN customer_audit.userid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_audit.userid IS 'Новое значение';


--
-- TOC entry 4245 (class 0 OID 0)
-- Dependencies: 263
-- Name: COLUMN customer_audit.entity_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_audit.entity_id IS 'Идентификатор изменившейся записи';


--
-- TOC entry 4246 (class 0 OID 0)
-- Dependencies: 263
-- Name: COLUMN customer_audit.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_audit.mdm_id IS 'MDM ID клиента';


--
-- TOC entry 4247 (class 0 OID 0)
-- Dependencies: 263
-- Name: COLUMN customer_audit.last_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_audit.last_name IS 'Фамилия клиента';


--
-- TOC entry 4248 (class 0 OID 0)
-- Dependencies: 263
-- Name: COLUMN customer_audit.first_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_audit.first_name IS 'Имя клиента';


--
-- TOC entry 4249 (class 0 OID 0)
-- Dependencies: 263
-- Name: COLUMN customer_audit.middle_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_audit.middle_name IS 'Отчество клиента';


--
-- TOC entry 4250 (class 0 OID 0)
-- Dependencies: 263
-- Name: COLUMN customer_audit.service_pack; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_audit.service_pack IS 'Пакет услуг';


--
-- TOC entry 262 (class 1259 OID 569789)
-- Name: customer_audit_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 293 (class 1259 OID 569962)
-- Name: customer_card_access; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_card_access (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    start_dt timestamp without time zone NOT NULL,
    end_dt timestamp without time zone NOT NULL,
    login character varying(50),
    permanent boolean,
    all_branches boolean
);


--
-- TOC entry 4251 (class 0 OID 0)
-- Dependencies: 293
-- Name: TABLE customer_card_access; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_card_access IS 'Безверификационный доступ к Карточке Клиента';


--
-- TOC entry 4252 (class 0 OID 0)
-- Dependencies: 293
-- Name: COLUMN customer_card_access.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access.id IS 'Идентификатор';


--
-- TOC entry 4253 (class 0 OID 0)
-- Dependencies: 293
-- Name: COLUMN customer_card_access.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4254 (class 0 OID 0)
-- Dependencies: 293
-- Name: COLUMN customer_card_access.start_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access.start_dt IS 'Дата и время начала доступа без верификации';


--
-- TOC entry 4255 (class 0 OID 0)
-- Dependencies: 293
-- Name: COLUMN customer_card_access.end_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access.end_dt IS 'Дата и время окончания доступа без верификации';


--
-- TOC entry 4256 (class 0 OID 0)
-- Dependencies: 293
-- Name: COLUMN customer_card_access.login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access.login IS 'Логин сотрудника, предоставившего/запретившего доступ к клиенту без верификации';


--
-- TOC entry 4257 (class 0 OID 0)
-- Dependencies: 293
-- Name: COLUMN customer_card_access.permanent; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access.permanent IS 'Поле обозначающее, что доступ был выдан на всю жизнь';


--
-- TOC entry 4258 (class 0 OID 0)
-- Dependencies: 293
-- Name: COLUMN customer_card_access.all_branches; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access.all_branches IS 'Поле обозначающее наличие доступа без верификации у всех ТП';


--
-- TOC entry 295 (class 1259 OID 569974)
-- Name: customer_card_access_audit; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_card_access_audit (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    userid character varying(64) NOT NULL,
    entity_id bigint NOT NULL,
    customer_id bigint,
    start_dt timestamp without time zone NOT NULL,
    end_dt timestamp without time zone NOT NULL,
    login character varying(50),
    permanent boolean,
    all_branches boolean
);


--
-- TOC entry 4259 (class 0 OID 0)
-- Dependencies: 295
-- Name: TABLE customer_card_access_audit; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_card_access_audit IS 'История изменений данных в таблице customer_card_access';


--
-- TOC entry 4260 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.id IS 'Идентификатор';


--
-- TOC entry 4261 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4262 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.stamp IS 'Дата и время изменения';


--
-- TOC entry 4263 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.userid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.userid IS 'Новое значение';


--
-- TOC entry 4264 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.entity_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.entity_id IS 'Идентификатор изменившейся записи';


--
-- TOC entry 4265 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4266 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.start_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.start_dt IS 'Дата и время начала доступа без верификации';


--
-- TOC entry 4267 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.end_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.end_dt IS 'Дата и время окончания доступа без верификации';


--
-- TOC entry 4268 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.login IS 'Логин сотрудника, предоставившего/запретившего доступ к клиенту без верификации';


--
-- TOC entry 4269 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.permanent; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.permanent IS 'Поле обозначающее, что доступ был выдан на всю жизнь';


--
-- TOC entry 4270 (class 0 OID 0)
-- Dependencies: 295
-- Name: COLUMN customer_card_access_audit.all_branches; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_audit.all_branches IS 'Поле обозначающее наличие доступа без верификации у всех ТП';


--
-- TOC entry 294 (class 1259 OID 569973)
-- Name: customer_card_access_audit_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_card_access_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_card_access_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 305 (class 1259 OID 570025)
-- Name: customer_card_access_branch; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_card_access_branch (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    branch_id bigint NOT NULL
);


--
-- TOC entry 4271 (class 0 OID 0)
-- Dependencies: 305
-- Name: TABLE customer_card_access_branch; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_card_access_branch IS 'Безверификационный доступ к Карточке Клиента, связки с ТП';


--
-- TOC entry 4272 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN customer_card_access_branch.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_branch.id IS 'Идентификатор';


--
-- TOC entry 4273 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN customer_card_access_branch.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_branch.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4274 (class 0 OID 0)
-- Dependencies: 305
-- Name: COLUMN customer_card_access_branch.branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_branch.branch_id IS 'Ссылка на ТП';


--
-- TOC entry 304 (class 1259 OID 570024)
-- Name: customer_card_access_branch_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_card_access_branch ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_card_access_branch_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 347 (class 1259 OID 570320)
-- Name: customer_card_access_employee; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_card_access_employee (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    login character varying(50) NOT NULL,
    start_dt timestamp without time zone NOT NULL,
    end_dt timestamp without time zone NOT NULL
);


--
-- TOC entry 4275 (class 0 OID 0)
-- Dependencies: 347
-- Name: TABLE customer_card_access_employee; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_card_access_employee IS 'Безверификационный доступ сотрудников к карточкам клиентам';


--
-- TOC entry 4276 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN customer_card_access_employee.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_employee.id IS 'Идентификатор';


--
-- TOC entry 4277 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN customer_card_access_employee.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_employee.customer_id IS 'Идентификатор клиента';


--
-- TOC entry 4278 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN customer_card_access_employee.login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_employee.login IS 'Логин сотрудника, которому предоставили безверификационный доступ';


--
-- TOC entry 4279 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN customer_card_access_employee.start_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_employee.start_dt IS 'Дата и время начала доступа без верификации';


--
-- TOC entry 4280 (class 0 OID 0)
-- Dependencies: 347
-- Name: COLUMN customer_card_access_employee.end_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_employee.end_dt IS 'Дата и время окончания доступа без верификации';


--
-- TOC entry 346 (class 1259 OID 570319)
-- Name: customer_card_access_employee_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_card_access_employee ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_card_access_employee_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 292 (class 1259 OID 569961)
-- Name: customer_card_access_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_card_access ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_card_access_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 307 (class 1259 OID 570041)
-- Name: customer_card_access_request_log; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_card_access_request_log (
    id bigint NOT NULL,
    mdm_id character varying(50) NOT NULL,
    login character varying(50) NOT NULL,
    allowed boolean,
    error_message character varying(512),
    request_dt timestamp without time zone NOT NULL
);


--
-- TOC entry 4281 (class 0 OID 0)
-- Dependencies: 307
-- Name: TABLE customer_card_access_request_log; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_card_access_request_log IS 'Таблица, логгирующая все запросы и ответы метода POST ext/check/personalManager';


--
-- TOC entry 4282 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN customer_card_access_request_log.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_request_log.id IS 'Идентификатор';


--
-- TOC entry 4283 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN customer_card_access_request_log.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_request_log.mdm_id IS 'mdm_id клиента из запроса POST ext/check/personalManager';


--
-- TOC entry 4284 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN customer_card_access_request_log.login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_request_log.login IS 'login сотрудника из запроса POST ext/check/personalManager';


--
-- TOC entry 4285 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN customer_card_access_request_log.allowed; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_request_log.allowed IS 'Разрешение на доступ сотрудника в карточку клиента без верификации. Значение поля isAllowed в ответе на запрос POST ext/check/personalManager';


--
-- TOC entry 4286 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN customer_card_access_request_log.error_message; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_request_log.error_message IS 'Текст ошибки, произошедшей при запросе';


--
-- TOC entry 4287 (class 0 OID 0)
-- Dependencies: 307
-- Name: COLUMN customer_card_access_request_log.request_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_card_access_request_log.request_dt IS 'Дата и время совершения запроса на доступ без верификации(текущая дата и время)';


--
-- TOC entry 306 (class 1259 OID 570040)
-- Name: customer_card_access_request_log_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_card_access_request_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_card_access_request_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 315 (class 1259 OID 570109)
-- Name: customer_churn; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_churn (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    initiator_id bigint,
    old_employee_id bigint,
    old_employee_role character varying(50) NOT NULL,
    old_customer_branch_id bigint NOT NULL,
    churn_type character varying(50) NOT NULL,
    churn_info character varying(2024) NOT NULL,
    event_date timestamp without time zone NOT NULL
);


--
-- TOC entry 4288 (class 0 OID 0)
-- Dependencies: 315
-- Name: TABLE customer_churn; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_churn IS 'Отток клиентов';


--
-- TOC entry 4289 (class 0 OID 0)
-- Dependencies: 315
-- Name: COLUMN customer_churn.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn.id IS 'Идентификатор';


--
-- TOC entry 4290 (class 0 OID 0)
-- Dependencies: 315
-- Name: COLUMN customer_churn.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4291 (class 0 OID 0)
-- Dependencies: 315
-- Name: COLUMN customer_churn.initiator_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn.initiator_id IS 'Ссылка на инициатора';


--
-- TOC entry 4292 (class 0 OID 0)
-- Dependencies: 315
-- Name: COLUMN customer_churn.old_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn.old_employee_id IS 'Ссылка на прежнего сотрудника';


--
-- TOC entry 4293 (class 0 OID 0)
-- Dependencies: 315
-- Name: COLUMN customer_churn.old_employee_role; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn.old_employee_role IS 'Роль прежнего сотрудника в команде обслуживания';


--
-- TOC entry 4294 (class 0 OID 0)
-- Dependencies: 315
-- Name: COLUMN customer_churn.old_customer_branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn.old_customer_branch_id IS 'Прежнее отделение клиента';


--
-- TOC entry 4295 (class 0 OID 0)
-- Dependencies: 315
-- Name: COLUMN customer_churn.churn_type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn.churn_type IS 'Тип события оттока';


--
-- TOC entry 4296 (class 0 OID 0)
-- Dependencies: 315
-- Name: COLUMN customer_churn.churn_info; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn.churn_info IS 'Параметры события оттока в json формате';


--
-- TOC entry 4297 (class 0 OID 0)
-- Dependencies: 315
-- Name: COLUMN customer_churn.event_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn.event_date IS 'Дата события оттока';


--
-- TOC entry 345 (class 1259 OID 570311)
-- Name: customer_churn_archive; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_churn_archive (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    initiator_id bigint,
    old_employee_id bigint,
    old_employee_role character varying(50) NOT NULL,
    old_customer_branch_id bigint NOT NULL,
    churn_type character varying(50) NOT NULL,
    churn_info character varying(2024) NOT NULL,
    event_date timestamp without time zone NOT NULL
);


--
-- TOC entry 4298 (class 0 OID 0)
-- Dependencies: 345
-- Name: TABLE customer_churn_archive; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_churn_archive IS 'Таблица для хранения архивных данных оттока клиентов';


--
-- TOC entry 4299 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN customer_churn_archive.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_archive.id IS 'Идентификатор';


--
-- TOC entry 4300 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN customer_churn_archive.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_archive.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4301 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN customer_churn_archive.initiator_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_archive.initiator_id IS 'Ссылка на инициатора';


--
-- TOC entry 4302 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN customer_churn_archive.old_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_archive.old_employee_id IS 'Ссылка на прежнего сотрудника';


--
-- TOC entry 4303 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN customer_churn_archive.old_employee_role; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_archive.old_employee_role IS 'Роль прежнего сотрудника в команде обслуживания';


--
-- TOC entry 4304 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN customer_churn_archive.old_customer_branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_archive.old_customer_branch_id IS 'Прежнее отделение клиента';


--
-- TOC entry 4305 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN customer_churn_archive.churn_type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_archive.churn_type IS 'Тип события оттока';


--
-- TOC entry 4306 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN customer_churn_archive.churn_info; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_archive.churn_info IS 'Параметры события оттока в json формате';


--
-- TOC entry 4307 (class 0 OID 0)
-- Dependencies: 345
-- Name: COLUMN customer_churn_archive.event_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_archive.event_date IS 'Дата события оттока';


--
-- TOC entry 344 (class 1259 OID 570310)
-- Name: customer_churn_archive_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_churn_archive ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_churn_archive_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 314 (class 1259 OID 570108)
-- Name: customer_churn_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_churn ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_churn_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 317 (class 1259 OID 570134)
-- Name: customer_churn_notification; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_churn_notification (
    id integer NOT NULL,
    customer_churn_id bigint NOT NULL,
    employee_id bigint NOT NULL,
    role character varying(50) NOT NULL
);


--
-- TOC entry 4308 (class 0 OID 0)
-- Dependencies: 317
-- Name: TABLE customer_churn_notification; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_churn_notification IS 'Нотификации для вкладки отток клиентов';


--
-- TOC entry 4309 (class 0 OID 0)
-- Dependencies: 317
-- Name: COLUMN customer_churn_notification.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_notification.id IS 'Идентификатор';


--
-- TOC entry 4310 (class 0 OID 0)
-- Dependencies: 317
-- Name: COLUMN customer_churn_notification.customer_churn_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_notification.customer_churn_id IS 'Ссылка на идетнификатор в таблице оттока клиентов';


--
-- TOC entry 4311 (class 0 OID 0)
-- Dependencies: 317
-- Name: COLUMN customer_churn_notification.employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_notification.employee_id IS 'Ссылка на сотрудника';


--
-- TOC entry 4312 (class 0 OID 0)
-- Dependencies: 317
-- Name: COLUMN customer_churn_notification.role; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_churn_notification.role IS 'Роль сотрудника в команде обслуживания';


--
-- TOC entry 316 (class 1259 OID 570133)
-- Name: customer_churn_notification_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_churn_notification ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_churn_notification_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 220 (class 1259 OID 569399)
-- Name: customer_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 374 (class 1259 OID 946954)
-- Name: customer_note; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_note (
    id bigint NOT NULL,
    content character varying(2000) NOT NULL,
    potential_customer_id bigint NOT NULL,
    update_date timestamp without time zone NOT NULL,
    login character varying(50) NOT NULL
);


--
-- TOC entry 4313 (class 0 OID 0)
-- Dependencies: 374
-- Name: COLUMN customer_note.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_note.id IS 'Идентификатор заметки';


--
-- TOC entry 4314 (class 0 OID 0)
-- Dependencies: 374
-- Name: COLUMN customer_note.content; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_note.content IS 'Содержание заметки';


--
-- TOC entry 4315 (class 0 OID 0)
-- Dependencies: 374
-- Name: COLUMN customer_note.potential_customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_note.potential_customer_id IS 'Идентификатор клиента';


--
-- TOC entry 4316 (class 0 OID 0)
-- Dependencies: 374
-- Name: COLUMN customer_note.update_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_note.update_date IS 'Дата создания/изменения заметки';


--
-- TOC entry 4317 (class 0 OID 0)
-- Dependencies: 374
-- Name: COLUMN customer_note.login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_note.login IS 'Логин сотрудника, который создал или отредактировал заметку';


--
-- TOC entry 373 (class 1259 OID 946953)
-- Name: customer_note_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_note ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_note_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 245 (class 1259 OID 569646)
-- Name: customer_prime; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_prime (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    temp_group_exp_date timestamp without time zone,
    group_id integer,
    vip boolean DEFAULT false NOT NULL,
    top boolean DEFAULT false NOT NULL,
    vip_confirmed boolean DEFAULT false NOT NULL
);


--
-- TOC entry 4318 (class 0 OID 0)
-- Dependencies: 245
-- Name: TABLE customer_prime; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_prime IS 'Дополнтельная информация по клиентам прайм';


--
-- TOC entry 4319 (class 0 OID 0)
-- Dependencies: 245
-- Name: COLUMN customer_prime.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime.id IS 'Идентификатор';


--
-- TOC entry 4320 (class 0 OID 0)
-- Dependencies: 245
-- Name: COLUMN customer_prime.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4321 (class 0 OID 0)
-- Dependencies: 245
-- Name: COLUMN customer_prime.temp_group_exp_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime.temp_group_exp_date IS 'Окончание действия договора для временной группы';


--
-- TOC entry 4322 (class 0 OID 0)
-- Dependencies: 245
-- Name: COLUMN customer_prime.group_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime.group_id IS 'Идентификатор группы (id таблицы group_prime)';


--
-- TOC entry 4323 (class 0 OID 0)
-- Dependencies: 245
-- Name: COLUMN customer_prime.vip; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime.vip IS 'Признак VIP';


--
-- TOC entry 4324 (class 0 OID 0)
-- Dependencies: 245
-- Name: COLUMN customer_prime.top; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime.top IS 'Признак TOP';


--
-- TOC entry 4325 (class 0 OID 0)
-- Dependencies: 245
-- Name: COLUMN customer_prime.vip_confirmed; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime.vip_confirmed IS 'Признак подтверждения Карточкой ФЛ';


--
-- TOC entry 265 (class 1259 OID 569800)
-- Name: customer_prime_audit; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_prime_audit (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    userid character varying(64) NOT NULL,
    entity_id bigint NOT NULL,
    customer_id bigint,
    group_id integer,
    temp_group_exp_date timestamp without time zone,
    vip boolean,
    top boolean,
    vip_confirmed boolean
);


--
-- TOC entry 4326 (class 0 OID 0)
-- Dependencies: 265
-- Name: TABLE customer_prime_audit; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_prime_audit IS 'История изменений данных в таблице customer_prime';


--
-- TOC entry 4327 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.id IS 'Идентификатор';


--
-- TOC entry 4328 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4329 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.stamp IS 'Дата и время изменения';


--
-- TOC entry 4330 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.userid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.userid IS 'Новое значение';


--
-- TOC entry 4331 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.entity_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.entity_id IS 'Идентификатор изменившейся записи';


--
-- TOC entry 4332 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4333 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.group_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.group_id IS 'Идентификатор группы (id таблицы group_prime)';


--
-- TOC entry 4334 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.temp_group_exp_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.temp_group_exp_date IS 'Окончание действия договора для временной группы';


--
-- TOC entry 4335 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.vip; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.vip IS 'Признак VIP';


--
-- TOC entry 4336 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.top; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.top IS 'Признак TOP';


--
-- TOC entry 4337 (class 0 OID 0)
-- Dependencies: 265
-- Name: COLUMN customer_prime_audit.vip_confirmed; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_prime_audit.vip_confirmed IS 'Признак подтверждения Карточкой ФЛ';


--
-- TOC entry 264 (class 1259 OID 569799)
-- Name: customer_prime_audit_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_prime_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_prime_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 244 (class 1259 OID 569645)
-- Name: customer_prime_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_prime ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_prime_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 339 (class 1259 OID 570264)
-- Name: customer_privilege; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_privilege (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    privilege boolean NOT NULL,
    group_id bigint
);


--
-- TOC entry 4338 (class 0 OID 0)
-- Dependencies: 339
-- Name: TABLE customer_privilege; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_privilege IS 'Клиенты с командой обслуживания Привиления';


--
-- TOC entry 4339 (class 0 OID 0)
-- Dependencies: 339
-- Name: COLUMN customer_privilege.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_privilege.id IS 'Идентификатор';


--
-- TOC entry 4340 (class 0 OID 0)
-- Dependencies: 339
-- Name: COLUMN customer_privilege.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_privilege.customer_id IS 'Идентификатор клиента';


--
-- TOC entry 4341 (class 0 OID 0)
-- Dependencies: 339
-- Name: COLUMN customer_privilege.privilege; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_privilege.privilege IS 'Метка Привилегия';


--
-- TOC entry 4342 (class 0 OID 0)
-- Dependencies: 339
-- Name: COLUMN customer_privilege.group_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_privilege.group_id IS 'Идентификатор группы обслуживания';


--
-- TOC entry 338 (class 1259 OID 570263)
-- Name: customer_privilege_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_privilege ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_privilege_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 327 (class 1259 OID 570203)
-- Name: customer_to_company; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_to_company (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    company_id bigint NOT NULL,
    is_main boolean DEFAULT true NOT NULL,
    date_added timestamp without time zone NOT NULL,
    client_position character varying(255)
);


--
-- TOC entry 4343 (class 0 OID 0)
-- Dependencies: 327
-- Name: TABLE customer_to_company; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_to_company IS 'Связка клиентов и организаций';


--
-- TOC entry 4344 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN customer_to_company.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_company.id IS 'Идентификатор';


--
-- TOC entry 4345 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN customer_to_company.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_company.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4346 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN customer_to_company.company_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_company.company_id IS 'Ссылка на компанию';


--
-- TOC entry 4347 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN customer_to_company.is_main; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_company.is_main IS 'Основная организация клиента';


--
-- TOC entry 4348 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN customer_to_company.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_company.date_added IS 'Дата добавления компании к клиенту';


--
-- TOC entry 4349 (class 0 OID 0)
-- Dependencies: 327
-- Name: COLUMN customer_to_company.client_position; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_company.client_position IS 'Должность клиента в организации';


--
-- TOC entry 326 (class 1259 OID 570202)
-- Name: customer_to_company_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_to_company ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_to_company_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 349 (class 1259 OID 570332)
-- Name: customer_to_deleted_employee; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_to_deleted_employee (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    role_in_team character varying(50) NOT NULL,
    employee_id bigint NOT NULL,
    branch_id bigint NOT NULL,
    rst_group_id bigint,
    date_start timestamp without time zone DEFAULT now() NOT NULL,
    date_end timestamp without time zone NOT NULL
);


--
-- TOC entry 4350 (class 0 OID 0)
-- Dependencies: 349
-- Name: TABLE customer_to_deleted_employee; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_to_deleted_employee IS 'Таблица связей клиентов и удалённых сотрудников';


--
-- TOC entry 4351 (class 0 OID 0)
-- Dependencies: 349
-- Name: COLUMN customer_to_deleted_employee.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_deleted_employee.id IS 'Идентификатор';


--
-- TOC entry 4352 (class 0 OID 0)
-- Dependencies: 349
-- Name: COLUMN customer_to_deleted_employee.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_deleted_employee.customer_id IS 'Идентификатор клиента';


--
-- TOC entry 4353 (class 0 OID 0)
-- Dependencies: 349
-- Name: COLUMN customer_to_deleted_employee.role_in_team; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_deleted_employee.role_in_team IS 'Роль сотрудника, с которой он был закреплен за клиентом';


--
-- TOC entry 4354 (class 0 OID 0)
-- Dependencies: 349
-- Name: COLUMN customer_to_deleted_employee.employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_deleted_employee.employee_id IS 'Идентификатор сотрудника';


--
-- TOC entry 4355 (class 0 OID 0)
-- Dependencies: 349
-- Name: COLUMN customer_to_deleted_employee.branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_deleted_employee.branch_id IS 'Идентификатор точки продаж';


--
-- TOC entry 4356 (class 0 OID 0)
-- Dependencies: 349
-- Name: COLUMN customer_to_deleted_employee.rst_group_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_deleted_employee.rst_group_id IS 'Идентификатор группы ДКО';


--
-- TOC entry 4357 (class 0 OID 0)
-- Dependencies: 349
-- Name: COLUMN customer_to_deleted_employee.date_start; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_deleted_employee.date_start IS 'Дата и время когда удалилась связка';


--
-- TOC entry 4358 (class 0 OID 0)
-- Dependencies: 349
-- Name: COLUMN customer_to_deleted_employee.date_end; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_deleted_employee.date_end IS 'Дата и время до которого необходимо хранить удаленную связку';


--
-- TOC entry 348 (class 1259 OID 570331)
-- Name: customer_to_deleted_employee_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_to_deleted_employee ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_to_deleted_employee_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 225 (class 1259 OID 569416)
-- Name: customer_to_employee; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_to_employee (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    service_team_member_id bigint,
    role_in_team character varying(50) NOT NULL,
    shifter_id bigint,
    branch_id integer,
    assigned_date timestamp without time zone DEFAULT now()
);


--
-- TOC entry 4359 (class 0 OID 0)
-- Dependencies: 225
-- Name: TABLE customer_to_employee; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_to_employee IS 'Сотрудники банка';


--
-- TOC entry 4360 (class 0 OID 0)
-- Dependencies: 225
-- Name: COLUMN customer_to_employee.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee.id IS 'Идентификатор';


--
-- TOC entry 4361 (class 0 OID 0)
-- Dependencies: 225
-- Name: COLUMN customer_to_employee.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4362 (class 0 OID 0)
-- Dependencies: 225
-- Name: COLUMN customer_to_employee.service_team_member_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee.service_team_member_id IS 'Ссылка на сотрудника - члена команды обслуживания';


--
-- TOC entry 4363 (class 0 OID 0)
-- Dependencies: 225
-- Name: COLUMN customer_to_employee.role_in_team; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee.role_in_team IS 'Роль сотрудника в команде обслуживания';


--
-- TOC entry 4364 (class 0 OID 0)
-- Dependencies: 225
-- Name: COLUMN customer_to_employee.shifter_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee.shifter_id IS 'Ссылка на временно замещающего';


--
-- TOC entry 4365 (class 0 OID 0)
-- Dependencies: 225
-- Name: COLUMN customer_to_employee.branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee.branch_id IS 'Ссылка на отделение';


--
-- TOC entry 4366 (class 0 OID 0)
-- Dependencies: 225
-- Name: COLUMN customer_to_employee.assigned_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee.assigned_date IS 'Дата закрепления клиента за данной ролью для отображения на UI(может отличаться от фактический даты закрепления за данной ролью)';


--
-- TOC entry 269 (class 1259 OID 569816)
-- Name: customer_to_employee_audit; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_to_employee_audit (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    userid character varying(64) NOT NULL,
    entity_id bigint NOT NULL,
    customer_id bigint,
    service_team_member_id bigint,
    role_in_team character varying(50),
    branch_id integer,
    shifter_id bigint,
    assigned_date timestamp without time zone
);


--
-- TOC entry 4367 (class 0 OID 0)
-- Dependencies: 269
-- Name: TABLE customer_to_employee_audit; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.customer_to_employee_audit IS 'История изменений данных в таблице customer_to_employee';


--
-- TOC entry 4368 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.id IS 'Идентификатор';


--
-- TOC entry 4369 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4370 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.stamp IS 'Дата и время изменения';


--
-- TOC entry 4371 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.userid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.userid IS 'Новое значение';


--
-- TOC entry 4372 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.entity_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.entity_id IS 'Идентификатор изменившейся записи';


--
-- TOC entry 4373 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4374 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.service_team_member_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.service_team_member_id IS 'Ссылка на сотрудника - члена команды обслуживания';


--
-- TOC entry 4375 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.role_in_team; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.role_in_team IS 'Роль сотрудника в команде обслуживания';


--
-- TOC entry 4376 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.branch_id IS 'Ссылка на отделение';


--
-- TOC entry 4377 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.shifter_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.shifter_id IS 'Ссылка на временно замещающего';


--
-- TOC entry 4378 (class 0 OID 0)
-- Dependencies: 269
-- Name: COLUMN customer_to_employee_audit.assigned_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_employee_audit.assigned_date IS 'Дата закрепления клиента за данной ролью для отображения на UI(может отличаться от фактический даты закрепления за данной ролью)';


--
-- TOC entry 268 (class 1259 OID 569815)
-- Name: customer_to_employee_audit_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_to_employee_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_to_employee_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 224 (class 1259 OID 569415)
-- Name: customer_to_employee_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_to_employee ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_to_employee_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 372 (class 1259 OID 946937)
-- Name: customer_to_tag; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.customer_to_tag (
    id bigint NOT NULL,
    potential_customer_id bigint NOT NULL,
    tag_id bigint NOT NULL,
    date_added timestamp without time zone NOT NULL
);


--
-- TOC entry 4379 (class 0 OID 0)
-- Dependencies: 372
-- Name: COLUMN customer_to_tag.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_tag.id IS 'Идентификатор записи';


--
-- TOC entry 4380 (class 0 OID 0)
-- Dependencies: 372
-- Name: COLUMN customer_to_tag.potential_customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_tag.potential_customer_id IS 'Идентификатор клиента из таблицы potential_customers';


--
-- TOC entry 4381 (class 0 OID 0)
-- Dependencies: 372
-- Name: COLUMN customer_to_tag.tag_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_tag.tag_id IS 'Идентификатор записи из таблицы tag';


--
-- TOC entry 4382 (class 0 OID 0)
-- Dependencies: 372
-- Name: COLUMN customer_to_tag.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.customer_to_tag.date_added IS 'Дата и время добавления заметки на клиенте';


--
-- TOC entry 371 (class 1259 OID 946936)
-- Name: customer_to_tag_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.customer_to_tag ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.customer_to_tag_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 218 (class 1259 OID 569389)
-- Name: databasechangelog; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.databasechangelog (
    id character varying(255) NOT NULL,
    author character varying(255) NOT NULL,
    filename character varying(255) NOT NULL,
    dateexecuted timestamp without time zone NOT NULL,
    orderexecuted integer NOT NULL,
    exectype character varying(10) NOT NULL,
    md5sum character varying(35),
    description character varying(255),
    comments character varying(255),
    tag character varying(255),
    liquibase character varying(20),
    contexts character varying(255),
    labels character varying(255),
    deployment_id character varying(10)
);


--
-- TOC entry 219 (class 1259 OID 569394)
-- Name: databasechangeloglock; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.databasechangeloglock (
    id integer NOT NULL,
    locked boolean NOT NULL,
    lockgranted timestamp without time zone,
    lockedby character varying(255)
);


--
-- TOC entry 301 (class 1259 OID 570000)
-- Name: dedup_backup_service_team; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.dedup_backup_service_team (
    id bigint NOT NULL,
    customer_mdm_id character varying(256) NOT NULL,
    customer_to_employee character varying,
    customer_prime character varying,
    affiliate character varying,
    temporary_shift character varying,
    delayed_shift character varying,
    create_dt timestamp without time zone DEFAULT now() NOT NULL,
    new_customer_mdm_id character varying(256)
);


--
-- TOC entry 4383 (class 0 OID 0)
-- Dependencies: 301
-- Name: TABLE dedup_backup_service_team; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.dedup_backup_service_team IS 'Резервное сохранение КО для процесса обратной дедупликации';


--
-- TOC entry 4384 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN dedup_backup_service_team.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_backup_service_team.id IS 'Идентификатор';


--
-- TOC entry 4385 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN dedup_backup_service_team.customer_mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_backup_service_team.customer_mdm_id IS 'MDM ID клиента';


--
-- TOC entry 4386 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN dedup_backup_service_team.customer_to_employee; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_backup_service_team.customer_to_employee IS 'запись в таблице customer_to_employee в json формате';


--
-- TOC entry 4387 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN dedup_backup_service_team.customer_prime; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_backup_service_team.customer_prime IS 'запись в таблице customer_prime в json формате';


--
-- TOC entry 4388 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN dedup_backup_service_team.affiliate; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_backup_service_team.affiliate IS 'запись в таблице affiliate в json формате';


--
-- TOC entry 4389 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN dedup_backup_service_team.temporary_shift; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_backup_service_team.temporary_shift IS 'запись в таблице temporary_shift в json формате';


--
-- TOC entry 4390 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN dedup_backup_service_team.delayed_shift; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_backup_service_team.delayed_shift IS 'запись в таблице delayed_shift в json формате';


--
-- TOC entry 4391 (class 0 OID 0)
-- Dependencies: 301
-- Name: COLUMN dedup_backup_service_team.create_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_backup_service_team.create_dt IS 'Дата и время создания';


--
-- TOC entry 300 (class 1259 OID 569999)
-- Name: dedup_backup_service_team_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.dedup_backup_service_team ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.dedup_backup_service_team_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 297 (class 1259 OID 569982)
-- Name: dedup_log; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.dedup_log (
    id bigint NOT NULL,
    action character varying(40) NOT NULL,
    old_mdm_id character varying(256) NOT NULL,
    new_mdm_id character varying(256) NOT NULL,
    dt timestamp without time zone NOT NULL,
    message character varying(512) NOT NULL
);


--
-- TOC entry 4392 (class 0 OID 0)
-- Dependencies: 297
-- Name: TABLE dedup_log; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.dedup_log IS 'Логирование сообщений дедупликации';


--
-- TOC entry 4393 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN dedup_log.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_log.id IS 'Идентификатор';


--
-- TOC entry 4394 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN dedup_log.action; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_log.action IS 'тип события';


--
-- TOC entry 4395 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN dedup_log.old_mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_log.old_mdm_id IS 'Старый MDM ID клиента';


--
-- TOC entry 4396 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN dedup_log.new_mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_log.new_mdm_id IS 'Новый MDM ID клиента';


--
-- TOC entry 4397 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN dedup_log.dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_log.dt IS 'Дата и время получения сообщения';


--
-- TOC entry 4398 (class 0 OID 0)
-- Dependencies: 297
-- Name: COLUMN dedup_log.message; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_log.message IS 'Тело сообщения кафки';


--
-- TOC entry 296 (class 1259 OID 569981)
-- Name: dedup_log_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.dedup_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.dedup_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 299 (class 1259 OID 569990)
-- Name: dedup_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.dedup_queue (
    id bigint NOT NULL,
    mdm_id character varying(256) NOT NULL,
    create_dt timestamp without time zone DEFAULT now() NOT NULL,
    last_processed_dt timestamp without time zone,
    error text,
    tries smallint DEFAULT 0
);


--
-- TOC entry 4399 (class 0 OID 0)
-- Dependencies: 299
-- Name: TABLE dedup_queue; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.dedup_queue IS 'Очередь для дедупликации текущих клиентов';


--
-- TOC entry 4400 (class 0 OID 0)
-- Dependencies: 299
-- Name: COLUMN dedup_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_queue.id IS 'Идентификатор';


--
-- TOC entry 4401 (class 0 OID 0)
-- Dependencies: 299
-- Name: COLUMN dedup_queue.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_queue.mdm_id IS 'MDM ID клиента';


--
-- TOC entry 4402 (class 0 OID 0)
-- Dependencies: 299
-- Name: COLUMN dedup_queue.create_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_queue.create_dt IS 'Дата и время создания';


--
-- TOC entry 4403 (class 0 OID 0)
-- Dependencies: 299
-- Name: COLUMN dedup_queue.last_processed_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_queue.last_processed_dt IS 'Дата последней обработки';


--
-- TOC entry 4404 (class 0 OID 0)
-- Dependencies: 299
-- Name: COLUMN dedup_queue.error; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_queue.error IS 'Описание ошибки, если возникла при обработке';


--
-- TOC entry 4405 (class 0 OID 0)
-- Dependencies: 299
-- Name: COLUMN dedup_queue.tries; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.dedup_queue.tries IS 'Количество попыток';


--
-- TOC entry 298 (class 1259 OID 569989)
-- Name: dedup_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.dedup_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.dedup_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 237 (class 1259 OID 569527)
-- Name: delayed_shift; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.delayed_shift (
    id bigint NOT NULL,
    customer_to_employee_id bigint NOT NULL,
    shifter_employee_id bigint NOT NULL,
    shift_date timestamp without time zone NOT NULL,
    permanent boolean DEFAULT false NOT NULL,
    return_date timestamp without time zone,
    shift_attempt_date timestamp without time zone,
    state_retry smallint NOT NULL,
    reason character varying(500) NOT NULL
);


--
-- TOC entry 4406 (class 0 OID 0)
-- Dependencies: 237
-- Name: TABLE delayed_shift; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.delayed_shift IS 'Отложенные замещения';


--
-- TOC entry 4407 (class 0 OID 0)
-- Dependencies: 237
-- Name: COLUMN delayed_shift.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift.id IS 'Идентификатор';


--
-- TOC entry 4408 (class 0 OID 0)
-- Dependencies: 237
-- Name: COLUMN delayed_shift.customer_to_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift.customer_to_employee_id IS 'Ссылка на подменяемое закрепление';


--
-- TOC entry 4409 (class 0 OID 0)
-- Dependencies: 237
-- Name: COLUMN delayed_shift.shifter_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift.shifter_employee_id IS 'Ссылка на замещающего сотрудника';


--
-- TOC entry 4410 (class 0 OID 0)
-- Dependencies: 237
-- Name: COLUMN delayed_shift.shift_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift.shift_date IS 'Дата начала замещения';


--
-- TOC entry 4411 (class 0 OID 0)
-- Dependencies: 237
-- Name: COLUMN delayed_shift.permanent; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift.permanent IS 'Флаг постоянности замещения';


--
-- TOC entry 4412 (class 0 OID 0)
-- Dependencies: 237
-- Name: COLUMN delayed_shift.return_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift.return_date IS 'Дата возврата';


--
-- TOC entry 4413 (class 0 OID 0)
-- Dependencies: 237
-- Name: COLUMN delayed_shift.shift_attempt_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift.shift_attempt_date IS 'Последняя дата попытки замещения';


--
-- TOC entry 4414 (class 0 OID 0)
-- Dependencies: 237
-- Name: COLUMN delayed_shift.state_retry; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift.state_retry IS 'Кол-во попыток выполнения';


--
-- TOC entry 4415 (class 0 OID 0)
-- Dependencies: 237
-- Name: COLUMN delayed_shift.reason; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift.reason IS 'Причина замещения';


--
-- TOC entry 277 (class 1259 OID 569852)
-- Name: delayed_shift_audit; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.delayed_shift_audit (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    userid character varying(64) NOT NULL,
    entity_id bigint NOT NULL,
    customer_to_employee_id bigint,
    shifter_employee_id bigint,
    shift_date timestamp without time zone,
    permanent boolean,
    return_date timestamp without time zone,
    shift_attempt_date timestamp without time zone,
    state_retry smallint,
    reason character varying(500)
);


--
-- TOC entry 4416 (class 0 OID 0)
-- Dependencies: 277
-- Name: TABLE delayed_shift_audit; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.delayed_shift_audit IS 'История изменений данных в таблице delayed_shift';


--
-- TOC entry 4417 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.id IS 'Идентификатор';


--
-- TOC entry 4418 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4419 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.stamp IS 'Дата и время изменения';


--
-- TOC entry 4420 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.userid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.userid IS 'Новое значение';


--
-- TOC entry 4421 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.entity_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.entity_id IS 'Идентификатор изменившейся записи';


--
-- TOC entry 4422 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.customer_to_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.customer_to_employee_id IS 'Ссылка на подменяемое закрепление';


--
-- TOC entry 4423 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.shifter_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.shifter_employee_id IS 'Ссылка на замещающего сотрудника';


--
-- TOC entry 4424 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.shift_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.shift_date IS 'Дата начала замещения';


--
-- TOC entry 4425 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.permanent; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.permanent IS 'Флаг постоянности замещения';


--
-- TOC entry 4426 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.return_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.return_date IS 'Дата возврата';


--
-- TOC entry 4427 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.shift_attempt_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.shift_attempt_date IS 'Последняя дата попытки замещения';


--
-- TOC entry 4428 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.state_retry; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.state_retry IS 'Кол-во попыток выполнения';


--
-- TOC entry 4429 (class 0 OID 0)
-- Dependencies: 277
-- Name: COLUMN delayed_shift_audit.reason; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.delayed_shift_audit.reason IS 'Причина замещения';


--
-- TOC entry 276 (class 1259 OID 569851)
-- Name: delayed_shift_audit_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.delayed_shift_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.delayed_shift_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 236 (class 1259 OID 569526)
-- Name: delayed_shift_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.delayed_shift ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.delayed_shift_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 239 (class 1259 OID 569559)
-- Name: disclaimer_milestone; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.disclaimer_milestone (
    id bigint NOT NULL,
    employee_id bigint NOT NULL,
    pm_new_shifts_date timestamp without time zone,
    type character varying(20),
    role_in_team character varying(50)
);


--
-- TOC entry 4430 (class 0 OID 0)
-- Dependencies: 239
-- Name: TABLE disclaimer_milestone; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.disclaimer_milestone IS 'Информация о закрытиях плашек информации';


--
-- TOC entry 4431 (class 0 OID 0)
-- Dependencies: 239
-- Name: COLUMN disclaimer_milestone.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.disclaimer_milestone.id IS 'Идентификатор';


--
-- TOC entry 4432 (class 0 OID 0)
-- Dependencies: 239
-- Name: COLUMN disclaimer_milestone.employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.disclaimer_milestone.employee_id IS 'Ссылка на сотрудника';


--
-- TOC entry 4433 (class 0 OID 0)
-- Dependencies: 239
-- Name: COLUMN disclaimer_milestone.pm_new_shifts_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.disclaimer_milestone.pm_new_shifts_date IS 'Дата нажатия на кнопку Закрыть';


--
-- TOC entry 4434 (class 0 OID 0)
-- Dependencies: 239
-- Name: COLUMN disclaimer_milestone.type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.disclaimer_milestone.type IS 'Тип плашки';


--
-- TOC entry 4435 (class 0 OID 0)
-- Dependencies: 239
-- Name: COLUMN disclaimer_milestone.role_in_team; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.disclaimer_milestone.role_in_team IS 'Роль сотрудника в команде';


--
-- TOC entry 238 (class 1259 OID 569558)
-- Name: disclaimer_milestone_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.disclaimer_milestone ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.disclaimer_milestone_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 223 (class 1259 OID 569408)
-- Name: employee; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.employee (
    id bigint NOT NULL,
    login character varying(50) NOT NULL,
    pers_num character varying(50) NOT NULL,
    first_name character varying(50),
    last_name character varying(50),
    middle_name character varying(50),
    phone_num character varying(40),
    work_phone_num character varying(40),
    work_phone_ext character varying(20),
    email character varying(50),
    fio character varying(160) GENERATED ALWAYS AS ((((lower((last_name)::text) || ' '::text) || lower((first_name)::text)) ||
CASE
    WHEN (middle_name IS NOT NULL) THEN (' '::text || lower((middle_name)::text))
    ELSE ''::text
END)) STORED,
    CONSTRAINT valid_login CHECK (((login)::text ~ similar_to_escape('[a-zA-Z0-9_.\-,]*'::text)))
);


--
-- TOC entry 4436 (class 0 OID 0)
-- Dependencies: 223
-- Name: TABLE employee; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.employee IS 'Сотрудники банка';


--
-- TOC entry 4437 (class 0 OID 0)
-- Dependencies: 223
-- Name: COLUMN employee.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee.id IS 'Идентификатор сотрудника банка';


--
-- TOC entry 4438 (class 0 OID 0)
-- Dependencies: 223
-- Name: COLUMN employee.login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee.login IS 'Логин сотрудника';


--
-- TOC entry 4439 (class 0 OID 0)
-- Dependencies: 223
-- Name: COLUMN employee.pers_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee.pers_num IS 'Табельный номер сотрудника';


--
-- TOC entry 4440 (class 0 OID 0)
-- Dependencies: 223
-- Name: COLUMN employee.first_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee.first_name IS 'Имя сотрудника';


--
-- TOC entry 4441 (class 0 OID 0)
-- Dependencies: 223
-- Name: COLUMN employee.last_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee.last_name IS 'Фамилия сотрудника';


--
-- TOC entry 4442 (class 0 OID 0)
-- Dependencies: 223
-- Name: COLUMN employee.middle_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee.middle_name IS 'Отчество сотрудника';


--
-- TOC entry 4443 (class 0 OID 0)
-- Dependencies: 223
-- Name: COLUMN employee.phone_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee.phone_num IS 'Мобильный номер телефона';


--
-- TOC entry 4444 (class 0 OID 0)
-- Dependencies: 223
-- Name: COLUMN employee.work_phone_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee.work_phone_num IS 'Рабочий номер телефона';


--
-- TOC entry 4445 (class 0 OID 0)
-- Dependencies: 223
-- Name: COLUMN employee.work_phone_ext; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee.work_phone_ext IS 'Добавочный номер';


--
-- TOC entry 275 (class 1259 OID 569844)
-- Name: employee_audit; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.employee_audit (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    userid character varying(64) NOT NULL,
    entity_id bigint NOT NULL,
    login character varying(50),
    pers_num character varying(50),
    last_name character varying(50),
    first_name character varying(50),
    middle_name character varying(50),
    phone_num character varying(40),
    work_phone_num character varying(40),
    work_phone_ext character varying(20),
    email character varying(50)
);


--
-- TOC entry 4446 (class 0 OID 0)
-- Dependencies: 275
-- Name: TABLE employee_audit; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.employee_audit IS 'История изменений данных в таблице employee';


--
-- TOC entry 4447 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.id IS 'Идентификатор';


--
-- TOC entry 4448 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4449 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.stamp IS 'Дата и время изменения';


--
-- TOC entry 4450 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.userid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.userid IS 'Новое значение';


--
-- TOC entry 4451 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.entity_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.entity_id IS 'Идентификатор изменившейся записи';


--
-- TOC entry 4452 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.login IS 'Логин сотрудника';


--
-- TOC entry 4453 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.pers_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.pers_num IS 'Табельный номер сотрудника';


--
-- TOC entry 4454 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.last_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.last_name IS 'Фамилия сотрудника';


--
-- TOC entry 4455 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.first_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.first_name IS 'Имя сотрудника';


--
-- TOC entry 4456 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.middle_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.middle_name IS 'Отчество сотрудника';


--
-- TOC entry 4457 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.phone_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.phone_num IS 'Мобильный номер телефона';


--
-- TOC entry 4458 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.work_phone_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.work_phone_num IS 'Рабочий номер телефона';


--
-- TOC entry 4459 (class 0 OID 0)
-- Dependencies: 275
-- Name: COLUMN employee_audit.work_phone_ext; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_audit.work_phone_ext IS 'Добавочный номер';


--
-- TOC entry 274 (class 1259 OID 569843)
-- Name: employee_audit_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.employee_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.employee_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 222 (class 1259 OID 569407)
-- Name: employee_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.employee ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.employee_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 231 (class 1259 OID 569455)
-- Name: employee_to_branch; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.employee_to_branch (
    id bigint NOT NULL,
    branch_id bigint NOT NULL,
    employee_id bigint NOT NULL,
    default_sv boolean DEFAULT false NOT NULL,
    next_actualization_at timestamp without time zone,
    role_bits integer DEFAULT 0 NOT NULL,
    department character varying(20)[],
    failed_attempts smallint,
    default_branch boolean,
    rst_group_id bigint,
    delete boolean,
    delete_dt timestamp without time zone
);


--
-- TOC entry 4460 (class 0 OID 0)
-- Dependencies: 231
-- Name: TABLE employee_to_branch; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.employee_to_branch IS 'Связь отделения с сотрудником';


--
-- TOC entry 4461 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.id IS 'Идентификатор';


--
-- TOC entry 4462 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.branch_id IS 'Ссылка на отделение';


--
-- TOC entry 4463 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.employee_id IS 'Ссылка на сотрудника отделения';


--
-- TOC entry 4464 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.default_sv; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.default_sv IS 'Супервизор по-умолчанию в отделении';


--
-- TOC entry 4465 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.next_actualization_at; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.next_actualization_at IS 'Дата следующей актуализации сотрудника из Карточки Сотрудника';


--
-- TOC entry 4466 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.role_bits; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.role_bits IS 'Роли в отделении';


--
-- TOC entry 4467 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.failed_attempts; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.failed_attempts IS 'Кол-во неудавшихся попыток получить информацию по сотруднику из КС';


--
-- TOC entry 4468 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.default_branch; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.default_branch IS 'Флаг актуальной ТП сотрудника';


--
-- TOC entry 4469 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.rst_group_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.rst_group_id IS 'Ссылка на группу обслуживания';


--
-- TOC entry 4470 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.delete; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.delete IS 'Признак того, что при запросе сотрудника в карточке сотрудника мы получили по его логину информацию о том, что сотрудник не найден';


--
-- TOC entry 4471 (class 0 OID 0)
-- Dependencies: 231
-- Name: COLUMN employee_to_branch.delete_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch.delete_dt IS 'Дата и время, когда первый раз по сотруднику получили информацию о том, что сотрудник не найден)';


--
-- TOC entry 273 (class 1259 OID 569834)
-- Name: employee_to_branch_audit; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.employee_to_branch_audit (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    userid character varying(64) NOT NULL,
    entity_id bigint NOT NULL,
    branch_id bigint,
    employee_id bigint,
    default_sv boolean,
    department character varying[],
    failed_attempts smallint,
    default_branch boolean,
    next_actualization_at timestamp without time zone,
    under_processing boolean,
    role_bits integer,
    rst_group_id bigint
);


--
-- TOC entry 4472 (class 0 OID 0)
-- Dependencies: 273
-- Name: TABLE employee_to_branch_audit; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.employee_to_branch_audit IS 'История изменений данных в таблице employee_to_branch';


--
-- TOC entry 4473 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.id IS 'Идентификатор';


--
-- TOC entry 4474 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4475 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.stamp IS 'Дата и время изменения';


--
-- TOC entry 4476 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.userid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.userid IS 'Новое значение';


--
-- TOC entry 4477 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.entity_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.entity_id IS 'Идентификатор изменившейся записи';


--
-- TOC entry 4478 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.branch_id IS 'Ссылка на отделение';


--
-- TOC entry 4479 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.employee_id IS 'Ссылка на сотрудника отделения';


--
-- TOC entry 4480 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.default_sv; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.default_sv IS 'Супервизор по-умолчанию в отделении';


--
-- TOC entry 4481 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.failed_attempts; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.failed_attempts IS 'Кол-во неудавшихся попыток получить информацию по сотруднику из КС';


--
-- TOC entry 4482 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.default_branch; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.default_branch IS 'Флаг актуальной ТП сотрудника';


--
-- TOC entry 4483 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.next_actualization_at; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.next_actualization_at IS 'Дата следующей актуализации сотрудника из Карточки Сотрудника';


--
-- TOC entry 4484 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.under_processing; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.under_processing IS 'Флаг для синхронизации';


--
-- TOC entry 4485 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.role_bits; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.role_bits IS 'Роли в отделении';


--
-- TOC entry 4486 (class 0 OID 0)
-- Dependencies: 273
-- Name: COLUMN employee_to_branch_audit.rst_group_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.employee_to_branch_audit.rst_group_id IS 'Ссылка на группу обслуживания';


--
-- TOC entry 272 (class 1259 OID 569833)
-- Name: employee_to_branch_audit_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.employee_to_branch_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.employee_to_branch_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 230 (class 1259 OID 569454)
-- Name: employee_to_branch_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.employee_to_branch ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.employee_to_branch_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 368 (class 1259 OID 914784)
-- Name: family_cs_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.family_cs_queue (
    id bigint NOT NULL,
    party_uid character varying(40) NOT NULL,
    related_party_uid character varying(40) NOT NULL,
    update_date_time timestamp without time zone NOT NULL,
    related_attrib2 character varying(30),
    end_date date,
    date_added timestamp without time zone NOT NULL,
    date_executed timestamp without time zone,
    error text,
    tries integer
);


--
-- TOC entry 4487 (class 0 OID 0)
-- Dependencies: 368
-- Name: TABLE family_cs_queue; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.family_cs_queue IS 'Очередь для обработки изменений по Группе Близкие из PersonPub';


--
-- TOC entry 4488 (class 0 OID 0)
-- Dependencies: 368
-- Name: COLUMN family_cs_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.family_cs_queue.id IS 'Идентификатор записи';


--
-- TOC entry 4489 (class 0 OID 0)
-- Dependencies: 368
-- Name: COLUMN family_cs_queue.party_uid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.family_cs_queue.party_uid IS 'mdmId владельца Группы Близкие';


--
-- TOC entry 4490 (class 0 OID 0)
-- Dependencies: 368
-- Name: COLUMN family_cs_queue.related_party_uid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.family_cs_queue.related_party_uid IS 'mdmId дочки в Группе Близкие';


--
-- TOC entry 4491 (class 0 OID 0)
-- Dependencies: 368
-- Name: COLUMN family_cs_queue.update_date_time; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.family_cs_queue.update_date_time IS 'Дата и время обновления записи в PersonPub';


--
-- TOC entry 4492 (class 0 OID 0)
-- Dependencies: 368
-- Name: COLUMN family_cs_queue.related_attrib2; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.family_cs_queue.related_attrib2 IS 'Статус связи в Группе Близкие';


--
-- TOC entry 4493 (class 0 OID 0)
-- Dependencies: 368
-- Name: COLUMN family_cs_queue.end_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.family_cs_queue.end_date IS 'Дата отключения связи в PersonPub';


--
-- TOC entry 4494 (class 0 OID 0)
-- Dependencies: 368
-- Name: COLUMN family_cs_queue.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.family_cs_queue.date_added IS 'Дата добавления в очередь';


--
-- TOC entry 4495 (class 0 OID 0)
-- Dependencies: 368
-- Name: COLUMN family_cs_queue.date_executed; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.family_cs_queue.date_executed IS 'Дата обработки очереди';


--
-- TOC entry 4496 (class 0 OID 0)
-- Dependencies: 368
-- Name: COLUMN family_cs_queue.error; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.family_cs_queue.error IS 'Описание технической ошибки';


--
-- TOC entry 4497 (class 0 OID 0)
-- Dependencies: 368
-- Name: COLUMN family_cs_queue.tries; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.family_cs_queue.tries IS 'Количество попыток (max = 5)';


--
-- TOC entry 367 (class 1259 OID 914783)
-- Name: family_cs_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.family_cs_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.family_cs_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 249 (class 1259 OID 569672)
-- Name: group_prime; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.group_prime (
    id integer NOT NULL,
    name character varying(256) NOT NULL,
    descr character varying(256) NOT NULL,
    group_number integer
);


--
-- TOC entry 4498 (class 0 OID 0)
-- Dependencies: 249
-- Name: TABLE group_prime; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.group_prime IS 'Группы обслуживания Кллиентов Прайм';


--
-- TOC entry 4499 (class 0 OID 0)
-- Dependencies: 249
-- Name: COLUMN group_prime.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.group_prime.id IS 'Идентификатор группы';


--
-- TOC entry 4500 (class 0 OID 0)
-- Dependencies: 249
-- Name: COLUMN group_prime.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.group_prime.name IS 'Название группы';


--
-- TOC entry 4501 (class 0 OID 0)
-- Dependencies: 249
-- Name: COLUMN group_prime.descr; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.group_prime.descr IS 'Описание группы';


--
-- TOC entry 4502 (class 0 OID 0)
-- Dependencies: 249
-- Name: COLUMN group_prime.group_number; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.group_prime.group_number IS 'Номер группы';


--
-- TOC entry 248 (class 1259 OID 569671)
-- Name: group_prime_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.group_prime ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.group_prime_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 337 (class 1259 OID 570256)
-- Name: group_privilege; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.group_privilege (
    id integer NOT NULL,
    name character varying(256) NOT NULL,
    "desc" character varying(255) NOT NULL,
    group_number bigint
);


--
-- TOC entry 4503 (class 0 OID 0)
-- Dependencies: 337
-- Name: TABLE group_privilege; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.group_privilege IS 'Группы обслуживания клиентов Привилегия';


--
-- TOC entry 4504 (class 0 OID 0)
-- Dependencies: 337
-- Name: COLUMN group_privilege.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.group_privilege.id IS 'Идентификатор';


--
-- TOC entry 4505 (class 0 OID 0)
-- Dependencies: 337
-- Name: COLUMN group_privilege.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.group_privilege.name IS 'Название группы';


--
-- TOC entry 4506 (class 0 OID 0)
-- Dependencies: 337
-- Name: COLUMN group_privilege."desc"; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.group_privilege."desc" IS 'Описание группы';


--
-- TOC entry 4507 (class 0 OID 0)
-- Dependencies: 337
-- Name: COLUMN group_privilege.group_number; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.group_privilege.group_number IS 'Номер  группы обслуживания';


--
-- TOC entry 336 (class 1259 OID 570255)
-- Name: group_privilege_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.group_privilege ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.group_privilege_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 341 (class 1259 OID 570274)
-- Name: import_account_manager; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.import_account_manager (
    id bigint NOT NULL,
    mdm_id character varying(50) NOT NULL,
    pers_num character varying(50) NOT NULL
);


--
-- TOC entry 4508 (class 0 OID 0)
-- Dependencies: 341
-- Name: TABLE import_account_manager; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.import_account_manager IS 'Таблица в которую ручками будем загружать клиентов и табельные номера сотрудников для создания связки в customer_to-employee с role_in_team = ''BILL_ACCOUNT_PRIVILEGE''';


--
-- TOC entry 4509 (class 0 OID 0)
-- Dependencies: 341
-- Name: COLUMN import_account_manager.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.import_account_manager.id IS 'Идентификатор';


--
-- TOC entry 4510 (class 0 OID 0)
-- Dependencies: 341
-- Name: COLUMN import_account_manager.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.import_account_manager.mdm_id IS 'mdm_id клиента';


--
-- TOC entry 4511 (class 0 OID 0)
-- Dependencies: 341
-- Name: COLUMN import_account_manager.pers_num; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.import_account_manager.pers_num IS 'Табельный номер сотрудника';


--
-- TOC entry 340 (class 1259 OID 570273)
-- Name: import_account_manager_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.import_account_manager ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.import_account_manager_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 247 (class 1259 OID 569658)
-- Name: import_failed; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.import_failed (
    id integer NOT NULL,
    mdm_id character varying(50),
    tab_num character varying(50),
    branch character varying(50),
    employee_error character varying(250),
    branch_error character varying(250)
);


--
-- TOC entry 4512 (class 0 OID 0)
-- Dependencies: 247
-- Name: TABLE import_failed; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.import_failed IS 'Ошибочные строки импорта';


--
-- TOC entry 4513 (class 0 OID 0)
-- Dependencies: 247
-- Name: COLUMN import_failed.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.import_failed.id IS 'Идентификатор';


--
-- TOC entry 246 (class 1259 OID 569657)
-- Name: import_failed_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.import_failed ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.import_failed_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 291 (class 1259 OID 569950)
-- Name: managing_director_central_office; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.managing_director_central_office (
    id bigint NOT NULL,
    employee_id bigint NOT NULL,
    is_privilege boolean,
    is_prime boolean
);


--
-- TOC entry 4514 (class 0 OID 0)
-- Dependencies: 291
-- Name: TABLE managing_director_central_office; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.managing_director_central_office IS 'Связь Управляющего Директора Сети (РСК) или Директора Инвестиционного Бизнесса с отделениями';


--
-- TOC entry 4515 (class 0 OID 0)
-- Dependencies: 291
-- Name: COLUMN managing_director_central_office.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.managing_director_central_office.id IS 'Идентификатор';


--
-- TOC entry 4516 (class 0 OID 0)
-- Dependencies: 291
-- Name: COLUMN managing_director_central_office.employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.managing_director_central_office.employee_id IS 'Ссылка на сотрудника (являющегося Управляющим Директором Сети (РСК) или Директором Инвестиционного Бизнесса)';


--
-- TOC entry 4517 (class 0 OID 0)
-- Dependencies: 291
-- Name: COLUMN managing_director_central_office.is_privilege; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.managing_director_central_office.is_privilege IS 'Сегмент клиентов Привилегия';


--
-- TOC entry 4518 (class 0 OID 0)
-- Dependencies: 291
-- Name: COLUMN managing_director_central_office.is_prime; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.managing_director_central_office.is_prime IS 'Сегмент клиентов Прайм';


--
-- TOC entry 290 (class 1259 OID 569949)
-- Name: managing_director_central_office_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.managing_director_central_office ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.managing_director_central_office_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 289 (class 1259 OID 569932)
-- Name: managing_director_rsk; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.managing_director_rsk (
    id bigint NOT NULL,
    employee_id bigint NOT NULL,
    branch_id bigint NOT NULL,
    is_privilege boolean,
    is_prime boolean
);


--
-- TOC entry 4519 (class 0 OID 0)
-- Dependencies: 289
-- Name: TABLE managing_director_rsk; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.managing_director_rsk IS 'Связь Управляющего Директора Сети (РСК) или Директора Инвестиционного Бизнесса с отделениями';


--
-- TOC entry 4520 (class 0 OID 0)
-- Dependencies: 289
-- Name: COLUMN managing_director_rsk.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.managing_director_rsk.id IS 'Идентификатор';


--
-- TOC entry 4521 (class 0 OID 0)
-- Dependencies: 289
-- Name: COLUMN managing_director_rsk.employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.managing_director_rsk.employee_id IS 'Ссылка на сотрудника (являющегося Управляющим Директором Сети (РСК) или Директором Инвестиционного Бизнесса)';


--
-- TOC entry 4522 (class 0 OID 0)
-- Dependencies: 289
-- Name: COLUMN managing_director_rsk.branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.managing_director_rsk.branch_id IS 'Ссылка на отделение';


--
-- TOC entry 4523 (class 0 OID 0)
-- Dependencies: 289
-- Name: COLUMN managing_director_rsk.is_privilege; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.managing_director_rsk.is_privilege IS 'Сегмент клиентов Привилегия';


--
-- TOC entry 4524 (class 0 OID 0)
-- Dependencies: 289
-- Name: COLUMN managing_director_rsk.is_prime; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.managing_director_rsk.is_prime IS 'Сегмент клиентов Прайм';


--
-- TOC entry 288 (class 1259 OID 569931)
-- Name: managing_director_rsk_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.managing_director_rsk ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.managing_director_rsk_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 343 (class 1259 OID 570280)
-- Name: mark_to_sofk_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.mark_to_sofk_queue (
    id bigint NOT NULL,
    customer_id integer NOT NULL,
    date_added timestamp without time zone NOT NULL,
    last_sent_dt timestamp without time zone,
    error text,
    status character varying(256) NOT NULL,
    mark_type character varying(64),
    mark_value boolean,
    group_number integer,
    group_name character varying(256)
);


--
-- TOC entry 4525 (class 0 OID 0)
-- Dependencies: 343
-- Name: TABLE mark_to_sofk_queue; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.mark_to_sofk_queue IS 'Очередь отправки меток (VIP,TOP,SUPERVIP) в SOFK';


--
-- TOC entry 4526 (class 0 OID 0)
-- Dependencies: 343
-- Name: COLUMN mark_to_sofk_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_sofk_queue.id IS 'Идентификатор';


--
-- TOC entry 4527 (class 0 OID 0)
-- Dependencies: 343
-- Name: COLUMN mark_to_sofk_queue.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_sofk_queue.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4528 (class 0 OID 0)
-- Dependencies: 343
-- Name: COLUMN mark_to_sofk_queue.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_sofk_queue.date_added IS 'Дата добавления в очередь';


--
-- TOC entry 4529 (class 0 OID 0)
-- Dependencies: 343
-- Name: COLUMN mark_to_sofk_queue.last_sent_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_sofk_queue.last_sent_dt IS 'Дата последней отправки';


--
-- TOC entry 4530 (class 0 OID 0)
-- Dependencies: 343
-- Name: COLUMN mark_to_sofk_queue.error; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_sofk_queue.error IS 'Описание ошибки, если возникла при отправке';


--
-- TOC entry 4531 (class 0 OID 0)
-- Dependencies: 343
-- Name: COLUMN mark_to_sofk_queue.status; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_sofk_queue.status IS 'Статус обработки сообщения';


--
-- TOC entry 4532 (class 0 OID 0)
-- Dependencies: 343
-- Name: COLUMN mark_to_sofk_queue.mark_type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_sofk_queue.mark_type IS 'Тип устанавливаемой метки, STRING (enum) = (VIP, TOP, SUPERVIP)';


--
-- TOC entry 4533 (class 0 OID 0)
-- Dependencies: 343
-- Name: COLUMN mark_to_sofk_queue.mark_value; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_sofk_queue.mark_value IS 'Значение метки, boolean(true/false)';


--
-- TOC entry 4534 (class 0 OID 0)
-- Dependencies: 343
-- Name: COLUMN mark_to_sofk_queue.group_number; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_sofk_queue.group_number IS 'Номер группы обслуживания';


--
-- TOC entry 4535 (class 0 OID 0)
-- Dependencies: 343
-- Name: COLUMN mark_to_sofk_queue.group_name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_sofk_queue.group_name IS 'Наименование группы обслуживания';


--
-- TOC entry 342 (class 1259 OID 570279)
-- Name: mark_to_sofk_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.mark_to_sofk_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.mark_to_sofk_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 285 (class 1259 OID 569903)
-- Name: mark_to_uasp_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.mark_to_uasp_queue (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    date_added timestamp without time zone NOT NULL,
    last_send_dt timestamp without time zone,
    error text,
    mark_type character varying(64) NOT NULL,
    mark_value boolean NOT NULL
);


--
-- TOC entry 4536 (class 0 OID 0)
-- Dependencies: 285
-- Name: TABLE mark_to_uasp_queue; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.mark_to_uasp_queue IS 'Очередь отправки меток (VIP,top,SuperVip) в УАСП(1557)';


--
-- TOC entry 4537 (class 0 OID 0)
-- Dependencies: 285
-- Name: COLUMN mark_to_uasp_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_uasp_queue.id IS 'Идентификатор';


--
-- TOC entry 4538 (class 0 OID 0)
-- Dependencies: 285
-- Name: COLUMN mark_to_uasp_queue.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_uasp_queue.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4539 (class 0 OID 0)
-- Dependencies: 285
-- Name: COLUMN mark_to_uasp_queue.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_uasp_queue.date_added IS 'Дата добавления в очередь';


--
-- TOC entry 4540 (class 0 OID 0)
-- Dependencies: 285
-- Name: COLUMN mark_to_uasp_queue.last_send_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_uasp_queue.last_send_dt IS 'Дата последней отправки';


--
-- TOC entry 4541 (class 0 OID 0)
-- Dependencies: 285
-- Name: COLUMN mark_to_uasp_queue.error; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_uasp_queue.error IS 'Описание ошибки, если возникла при отправке';


--
-- TOC entry 4542 (class 0 OID 0)
-- Dependencies: 285
-- Name: COLUMN mark_to_uasp_queue.mark_type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_uasp_queue.mark_type IS 'Тип устанавливаемой метки, STRING (enum) = (vip, top, supervip)';


--
-- TOC entry 4543 (class 0 OID 0)
-- Dependencies: 285
-- Name: COLUMN mark_to_uasp_queue.mark_value; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mark_to_uasp_queue.mark_value IS 'Значение метки, boolean(true/false)';


--
-- TOC entry 284 (class 1259 OID 569902)
-- Name: mark_to_uasp_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.mark_to_uasp_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.mark_to_uasp_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 283 (class 1259 OID 569882)
-- Name: mutator_changes; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.mutator_changes (
    id integer NOT NULL,
    mutator_id integer NOT NULL,
    group_rule character varying(256) NOT NULL,
    replacement text NOT NULL
);


--
-- TOC entry 4544 (class 0 OID 0)
-- Dependencies: 283
-- Name: TABLE mutator_changes; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.mutator_changes IS 'Таблица действий мутаторов с текстом результата';


--
-- TOC entry 4545 (class 0 OID 0)
-- Dependencies: 283
-- Name: COLUMN mutator_changes.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mutator_changes.id IS 'Идентификатор';


--
-- TOC entry 4546 (class 0 OID 0)
-- Dependencies: 283
-- Name: COLUMN mutator_changes.mutator_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mutator_changes.mutator_id IS 'Тип мутатора';


--
-- TOC entry 4547 (class 0 OID 0)
-- Dependencies: 283
-- Name: COLUMN mutator_changes.group_rule; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mutator_changes.group_rule IS 'Regex определяющий группу замены';


--
-- TOC entry 4548 (class 0 OID 0)
-- Dependencies: 283
-- Name: COLUMN mutator_changes.replacement; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mutator_changes.replacement IS 'Замена группы';


--
-- TOC entry 282 (class 1259 OID 569881)
-- Name: mutator_changes_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.mutator_changes ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.mutator_changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 281 (class 1259 OID 569872)
-- Name: mutators; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.mutators (
    id integer NOT NULL,
    name character varying(255),
    mutator_type character varying(20) NOT NULL,
    params_match_rule character varying(256) NOT NULL,
    return_match_rule character varying(256) NOT NULL,
    error_case boolean DEFAULT false NOT NULL
);


--
-- TOC entry 4549 (class 0 OID 0)
-- Dependencies: 281
-- Name: TABLE mutators; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.mutators IS 'Таблица настройки применимости мутаторов к методу';


--
-- TOC entry 4550 (class 0 OID 0)
-- Dependencies: 281
-- Name: COLUMN mutators.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mutators.id IS 'Идентификатор';


--
-- TOC entry 4551 (class 0 OID 0)
-- Dependencies: 281
-- Name: COLUMN mutators.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mutators.name IS 'Наименование мутатора';


--
-- TOC entry 4552 (class 0 OID 0)
-- Dependencies: 281
-- Name: COLUMN mutators.mutator_type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mutators.mutator_type IS 'Тип мутатора';


--
-- TOC entry 4553 (class 0 OID 0)
-- Dependencies: 281
-- Name: COLUMN mutators.params_match_rule; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mutators.params_match_rule IS 'Regex правило применимости мутатора для параметров';


--
-- TOC entry 4554 (class 0 OID 0)
-- Dependencies: 281
-- Name: COLUMN mutators.return_match_rule; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mutators.return_match_rule IS 'Regex правило применимости мутатора для результата';


--
-- TOC entry 4555 (class 0 OID 0)
-- Dependencies: 281
-- Name: COLUMN mutators.error_case; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.mutators.error_case IS 'Мутатор должен применяться в случае возникновения ошибки';


--
-- TOC entry 280 (class 1259 OID 569871)
-- Name: mutators_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.mutators ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.mutators_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 235 (class 1259 OID 569512)
-- Name: person_cs_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.person_cs_queue (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    date_added timestamp without time zone NOT NULL,
    date_executed timestamp without time zone,
    error text,
    tries smallint
);


--
-- TOC entry 4556 (class 0 OID 0)
-- Dependencies: 235
-- Name: TABLE person_cs_queue; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.person_cs_queue IS 'Очередь интеграции с МС ''Карточка ФЛ''';


--
-- TOC entry 4557 (class 0 OID 0)
-- Dependencies: 235
-- Name: COLUMN person_cs_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.person_cs_queue.id IS 'Идентификатор';


--
-- TOC entry 4558 (class 0 OID 0)
-- Dependencies: 235
-- Name: COLUMN person_cs_queue.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.person_cs_queue.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4559 (class 0 OID 0)
-- Dependencies: 235
-- Name: COLUMN person_cs_queue.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.person_cs_queue.date_added IS 'Дата добавления в очередь';


--
-- TOC entry 4560 (class 0 OID 0)
-- Dependencies: 235
-- Name: COLUMN person_cs_queue.date_executed; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.person_cs_queue.date_executed IS 'Дата обработки очеререди';


--
-- TOC entry 4561 (class 0 OID 0)
-- Dependencies: 235
-- Name: COLUMN person_cs_queue.error; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.person_cs_queue.error IS 'Описание ошибки';


--
-- TOC entry 4562 (class 0 OID 0)
-- Dependencies: 235
-- Name: COLUMN person_cs_queue.tries; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.person_cs_queue.tries IS 'Количество попыток';


--
-- TOC entry 234 (class 1259 OID 569511)
-- Name: person_cs_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.person_cs_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.person_cs_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 359 (class 1259 OID 570408)
-- Name: potential_customers; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.potential_customers (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    employee_id bigint,
    role character varying(50) NOT NULL,
    branch_id bigint NOT NULL,
    rst_group_id integer,
    date_added timestamp without time zone DEFAULT now() NOT NULL
);


--
-- TOC entry 4563 (class 0 OID 0)
-- Dependencies: 359
-- Name: TABLE potential_customers; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.potential_customers IS 'Потенциальные клиенты';


--
-- TOC entry 4564 (class 0 OID 0)
-- Dependencies: 359
-- Name: COLUMN potential_customers.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.potential_customers.id IS 'Идентификатор записи';


--
-- TOC entry 4565 (class 0 OID 0)
-- Dependencies: 359
-- Name: COLUMN potential_customers.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.potential_customers.customer_id IS 'Идентификатор потенциального клиента из таблицы customer';


--
-- TOC entry 4566 (class 0 OID 0)
-- Dependencies: 359
-- Name: COLUMN potential_customers.employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.potential_customers.employee_id IS 'Идентификатор сотрудника из таблицы employee, который добавил клиента в потенциального';


--
-- TOC entry 4567 (class 0 OID 0)
-- Dependencies: 359
-- Name: COLUMN potential_customers.role; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.potential_customers.role IS 'Роль сотрудника, который добавил клиента в потенциальные.';


--
-- TOC entry 4568 (class 0 OID 0)
-- Dependencies: 359
-- Name: COLUMN potential_customers.branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.potential_customers.branch_id IS 'Идентификатор отделения из таблицы branch в котором клиент числится потенциальным';


--
-- TOC entry 4569 (class 0 OID 0)
-- Dependencies: 359
-- Name: COLUMN potential_customers.rst_group_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.potential_customers.rst_group_id IS 'Идентификатор группы обслуживания ДКО из таблицы rst_group';


--
-- TOC entry 4570 (class 0 OID 0)
-- Dependencies: 359
-- Name: COLUMN potential_customers.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.potential_customers.date_added IS 'Дата и время добавления потенциального клиента';


--
-- TOC entry 358 (class 1259 OID 570407)
-- Name: potential_customers_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.potential_customers ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.potential_customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 227 (class 1259 OID 569437)
-- Name: processing_log; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.processing_log (
    id bigint NOT NULL,
    process_id uuid NOT NULL,
    type character varying(30) NOT NULL,
    process_start timestamp without time zone NOT NULL,
    process_end timestamp without time zone,
    state character varying(30) NOT NULL,
    description character varying(255) NOT NULL,
    state_retry smallint NOT NULL,
    version smallint NOT NULL,
    assignee_login character varying(50),
    client_mdm character varying(256),
    user_login character varying(50),
    branch_code character varying(50)
);


--
-- TOC entry 4571 (class 0 OID 0)
-- Dependencies: 227
-- Name: TABLE processing_log; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.processing_log IS 'Лог обработки запросов';


--
-- TOC entry 4572 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.id IS 'Идентификатор лога';


--
-- TOC entry 4573 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.process_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.process_id IS 'Уникальный идентификатор процесса';


--
-- TOC entry 4574 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.type IS 'Тип процесса';


--
-- TOC entry 4575 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.process_start; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.process_start IS 'Дата начала процесса';


--
-- TOC entry 4576 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.process_end; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.process_end IS 'Дата окончания процесса';


--
-- TOC entry 4577 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.state; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.state IS 'Текущая стадия процесса';


--
-- TOC entry 4578 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.description; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.description IS 'Описание текущей стадии процесса';


--
-- TOC entry 4579 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.state_retry; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.state_retry IS 'Кол-во попыток выполнения стадии';


--
-- TOC entry 4580 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.version; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.version IS 'Версия записи';


--
-- TOC entry 4581 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.assignee_login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.assignee_login IS 'Логин сотрудника для получения задачи в стакан задач';


--
-- TOC entry 4582 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.client_mdm; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.client_mdm IS 'MDM ID клиента';


--
-- TOC entry 4583 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.user_login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.user_login IS 'Логин сотрудника';


--
-- TOC entry 4584 (class 0 OID 0)
-- Dependencies: 227
-- Name: COLUMN processing_log.branch_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.processing_log.branch_code IS 'Код отделения';


--
-- TOC entry 226 (class 1259 OID 569436)
-- Name: processing_log_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.processing_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.processing_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 253 (class 1259 OID 569720)
-- Name: profile_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.profile_queue (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    date_added timestamp without time zone DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'utc'::text) NOT NULL,
    date_executed timestamp without time zone,
    error text,
    tries smallint,
    delay_check boolean DEFAULT false NOT NULL,
    pack_type character varying(20)
);


--
-- TOC entry 4585 (class 0 OID 0)
-- Dependencies: 253
-- Name: TABLE profile_queue; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.profile_queue IS 'Очередь интеграции с МС ''Профиль 360'' для проставления Пакета Услуг';


--
-- TOC entry 4586 (class 0 OID 0)
-- Dependencies: 253
-- Name: COLUMN profile_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.profile_queue.id IS 'Идентификатор';


--
-- TOC entry 4587 (class 0 OID 0)
-- Dependencies: 253
-- Name: COLUMN profile_queue.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.profile_queue.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4588 (class 0 OID 0)
-- Dependencies: 253
-- Name: COLUMN profile_queue.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.profile_queue.date_added IS 'Дата добавления в очередь';


--
-- TOC entry 4589 (class 0 OID 0)
-- Dependencies: 253
-- Name: COLUMN profile_queue.date_executed; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.profile_queue.date_executed IS 'Дата обработки очеререди';


--
-- TOC entry 4590 (class 0 OID 0)
-- Dependencies: 253
-- Name: COLUMN profile_queue.error; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.profile_queue.error IS 'Описание ошибки';


--
-- TOC entry 4591 (class 0 OID 0)
-- Dependencies: 253
-- Name: COLUMN profile_queue.tries; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.profile_queue.tries IS 'Количество попыток';


--
-- TOC entry 4592 (class 0 OID 0)
-- Dependencies: 253
-- Name: COLUMN profile_queue.delay_check; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.profile_queue.delay_check IS 'Отложенная перепроверка Пакета Услуг (внедрили для перепроверки полученного ПУ ''Мультикарта'' от УАСП)';


--
-- TOC entry 4593 (class 0 OID 0)
-- Dependencies: 253
-- Name: COLUMN profile_queue.pack_type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.profile_queue.pack_type IS 'Полученный от УАСП ПУ, который собираемся перепроверять';


--
-- TOC entry 252 (class 1259 OID 569719)
-- Name: profile_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.profile_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.profile_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 313 (class 1259 OID 570096)
-- Name: prospect; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.prospect (
    id bigint NOT NULL,
    customer_id bigint NOT NULL
);


--
-- TOC entry 4594 (class 0 OID 0)
-- Dependencies: 313
-- Name: TABLE prospect; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.prospect IS 'Проспект - клиент, созданный нами через УКД';


--
-- TOC entry 4595 (class 0 OID 0)
-- Dependencies: 313
-- Name: COLUMN prospect.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.prospect.id IS 'Идентификатор';


--
-- TOC entry 4596 (class 0 OID 0)
-- Dependencies: 313
-- Name: COLUMN prospect.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.prospect.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 312 (class 1259 OID 570095)
-- Name: prospect_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.prospect ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.prospect_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 319 (class 1259 OID 570161)
-- Name: relative; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.relative (
    id bigint NOT NULL,
    name character varying(25) NOT NULL,
    ext_code character varying(25) NOT NULL,
    sort_order integer NOT NULL
);


--
-- TOC entry 4597 (class 0 OID 0)
-- Dependencies: 319
-- Name: TABLE relative; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.relative IS 'Категории родства';


--
-- TOC entry 4598 (class 0 OID 0)
-- Dependencies: 319
-- Name: COLUMN relative.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.relative.id IS 'Идентификатор';


--
-- TOC entry 4599 (class 0 OID 0)
-- Dependencies: 319
-- Name: COLUMN relative.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.relative.name IS 'Наименование степени родства';


--
-- TOC entry 4600 (class 0 OID 0)
-- Dependencies: 319
-- Name: COLUMN relative.ext_code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.relative.ext_code IS 'Код степени родства';


--
-- TOC entry 4601 (class 0 OID 0)
-- Dependencies: 319
-- Name: COLUMN relative.sort_order; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.relative.sort_order IS 'Порядок для выдачи на UI';


--
-- TOC entry 318 (class 1259 OID 570160)
-- Name: relative_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.relative ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.relative_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 255 (class 1259 OID 569735)
-- Name: rst_group; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.rst_group (
    id bigint NOT NULL,
    name character varying(100),
    city character varying(50),
    ext_id integer,
    sort_order integer
);


--
-- TOC entry 4602 (class 0 OID 0)
-- Dependencies: 255
-- Name: TABLE rst_group; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.rst_group IS 'Группа обслуживания ДКО';


--
-- TOC entry 4603 (class 0 OID 0)
-- Dependencies: 255
-- Name: COLUMN rst_group.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.rst_group.id IS 'Идентификатор';


--
-- TOC entry 4604 (class 0 OID 0)
-- Dependencies: 255
-- Name: COLUMN rst_group.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.rst_group.name IS 'Наименование ДКО';


--
-- TOC entry 4605 (class 0 OID 0)
-- Dependencies: 255
-- Name: COLUMN rst_group.city; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.rst_group.city IS 'Город группы ДКО';


--
-- TOC entry 4606 (class 0 OID 0)
-- Dependencies: 255
-- Name: COLUMN rst_group.ext_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.rst_group.ext_id IS 'Внешний номер группы ДКО';


--
-- TOC entry 4607 (class 0 OID 0)
-- Dependencies: 255
-- Name: COLUMN rst_group.sort_order; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.rst_group.sort_order IS 'Порядок сортировки групп ДКО';


--
-- TOC entry 254 (class 1259 OID 569734)
-- Name: rst_group_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.rst_group ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.rst_group_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 243 (class 1259 OID 569621)
-- Name: service_team_import_status; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.service_team_import_status (
    id integer NOT NULL,
    customer_to_employee_id bigint NOT NULL,
    mdm_id character varying(50) NOT NULL,
    on_date date NOT NULL,
    branch_id integer,
    message character varying(255)
);


--
-- TOC entry 4608 (class 0 OID 0)
-- Dependencies: 243
-- Name: TABLE service_team_import_status; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.service_team_import_status IS 'Статус импорта КО';


--
-- TOC entry 4609 (class 0 OID 0)
-- Dependencies: 243
-- Name: COLUMN service_team_import_status.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_import_status.id IS 'Идентификатор';


--
-- TOC entry 4610 (class 0 OID 0)
-- Dependencies: 243
-- Name: COLUMN service_team_import_status.customer_to_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_import_status.customer_to_employee_id IS 'Ссылка на КО';


--
-- TOC entry 4611 (class 0 OID 0)
-- Dependencies: 243
-- Name: COLUMN service_team_import_status.branch_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_import_status.branch_id IS 'Ссылка на отделение';


--
-- TOC entry 4612 (class 0 OID 0)
-- Dependencies: 243
-- Name: COLUMN service_team_import_status.message; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_import_status.message IS 'Сообщение об ошибке';


--
-- TOC entry 242 (class 1259 OID 569620)
-- Name: service_team_import_status_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.service_team_import_status ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.service_team_import_status_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 321 (class 1259 OID 570173)
-- Name: service_team_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.service_team_queue (
    id bigint NOT NULL,
    mdm_id character varying(256) NOT NULL,
    date_added timestamp without time zone NOT NULL,
    last_send_dt timestamp without time zone,
    error character varying(2024),
    message character varying(2024) NOT NULL,
    status character varying(256) NOT NULL
);


--
-- TOC entry 4613 (class 0 OID 0)
-- Dependencies: 321
-- Name: TABLE service_team_queue; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.service_team_queue IS 'Стриминг команды обслуживания';


--
-- TOC entry 4614 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN service_team_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_queue.id IS 'Идентификатор';


--
-- TOC entry 4615 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN service_team_queue.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_queue.mdm_id IS 'MDM ID клиента';


--
-- TOC entry 4616 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN service_team_queue.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_queue.date_added IS 'Текущая дата и время';


--
-- TOC entry 4617 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN service_team_queue.last_send_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_queue.last_send_dt IS 'Дата и время изменения';


--
-- TOC entry 4618 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN service_team_queue.error; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_queue.error IS 'Описание ошибки';


--
-- TOC entry 4619 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN service_team_queue.message; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_queue.message IS 'Тело сообщения кафки';


--
-- TOC entry 4620 (class 0 OID 0)
-- Dependencies: 321
-- Name: COLUMN service_team_queue.status; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.service_team_queue.status IS 'Статус обработки сообщения';


--
-- TOC entry 320 (class 1259 OID 570172)
-- Name: service_team_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.service_team_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.service_team_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 259 (class 1259 OID 569759)
-- Name: sp_log; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.sp_log (
    id bigint NOT NULL,
    process_id character varying(50) NOT NULL,
    mdm_id character varying(256) NOT NULL,
    source character varying(30) NOT NULL,
    dt timestamp without time zone NOT NULL,
    message character varying(512) NOT NULL
);


--
-- TOC entry 4621 (class 0 OID 0)
-- Dependencies: 259
-- Name: TABLE sp_log; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.sp_log IS 'История сообщений от онбординга и uasp по смене ПУ';


--
-- TOC entry 4622 (class 0 OID 0)
-- Dependencies: 259
-- Name: COLUMN sp_log.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_log.id IS 'Идентификатор';


--
-- TOC entry 4623 (class 0 OID 0)
-- Dependencies: 259
-- Name: COLUMN sp_log.process_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_log.process_id IS 'Уникальный идентификатор процесса';


--
-- TOC entry 4624 (class 0 OID 0)
-- Dependencies: 259
-- Name: COLUMN sp_log.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_log.mdm_id IS 'MDM ID клиента';


--
-- TOC entry 4625 (class 0 OID 0)
-- Dependencies: 259
-- Name: COLUMN sp_log.source; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_log.source IS 'Источник сообщения';


--
-- TOC entry 4626 (class 0 OID 0)
-- Dependencies: 259
-- Name: COLUMN sp_log.dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_log.dt IS 'Дата и время получения сообщения';


--
-- TOC entry 4627 (class 0 OID 0)
-- Dependencies: 259
-- Name: COLUMN sp_log.message; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_log.message IS 'Тело сообщения кафки';


--
-- TOC entry 258 (class 1259 OID 569758)
-- Name: sp_log_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.sp_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.sp_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 261 (class 1259 OID 569768)
-- Name: sp_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.sp_queue (
    id bigint NOT NULL,
    mdm_id character varying(256) NOT NULL,
    dt timestamp without time zone NOT NULL,
    old_pack character varying(256),
    new_pack character varying(256) NOT NULL,
    is_affiliated boolean DEFAULT false
);


--
-- TOC entry 4628 (class 0 OID 0)
-- Dependencies: 261
-- Name: TABLE sp_queue; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.sp_queue IS 'Очередь изменений ПУ из UASP';


--
-- TOC entry 4629 (class 0 OID 0)
-- Dependencies: 261
-- Name: COLUMN sp_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue.id IS 'Идентификатор';


--
-- TOC entry 4630 (class 0 OID 0)
-- Dependencies: 261
-- Name: COLUMN sp_queue.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue.mdm_id IS 'MDM ID клиента';


--
-- TOC entry 4631 (class 0 OID 0)
-- Dependencies: 261
-- Name: COLUMN sp_queue.dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue.dt IS 'Дата и время получения сообщения';


--
-- TOC entry 4632 (class 0 OID 0)
-- Dependencies: 261
-- Name: COLUMN sp_queue.old_pack; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue.old_pack IS 'Старый ПУ';


--
-- TOC entry 4633 (class 0 OID 0)
-- Dependencies: 261
-- Name: COLUMN sp_queue.new_pack; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue.new_pack IS 'Новый ПУ';


--
-- TOC entry 4634 (class 0 OID 0)
-- Dependencies: 261
-- Name: COLUMN sp_queue.is_affiliated; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue.is_affiliated IS 'ПУ для аффилировнного лица';


--
-- TOC entry 260 (class 1259 OID 569767)
-- Name: sp_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.sp_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.sp_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 311 (class 1259 OID 570085)
-- Name: sp_queue_mo; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.sp_queue_mo (
    id bigint NOT NULL,
    sp_log_id bigint NOT NULL,
    date_added timestamp without time zone,
    last_sent_dt timestamp without time zone,
    tries smallint DEFAULT 0,
    exception text
);


--
-- TOC entry 4635 (class 0 OID 0)
-- Dependencies: 311
-- Name: TABLE sp_queue_mo; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.sp_queue_mo IS 'Очередь для сообщений из Manager Onboarding';


--
-- TOC entry 4636 (class 0 OID 0)
-- Dependencies: 311
-- Name: COLUMN sp_queue_mo.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue_mo.id IS 'Идентификатор';


--
-- TOC entry 4637 (class 0 OID 0)
-- Dependencies: 311
-- Name: COLUMN sp_queue_mo.sp_log_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue_mo.sp_log_id IS 'Ссылка на sp_log';


--
-- TOC entry 4638 (class 0 OID 0)
-- Dependencies: 311
-- Name: COLUMN sp_queue_mo.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue_mo.date_added IS 'Дата добавления';


--
-- TOC entry 4639 (class 0 OID 0)
-- Dependencies: 311
-- Name: COLUMN sp_queue_mo.last_sent_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue_mo.last_sent_dt IS 'Дата последней отправки';


--
-- TOC entry 4640 (class 0 OID 0)
-- Dependencies: 311
-- Name: COLUMN sp_queue_mo.tries; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue_mo.tries IS 'Количество попыток';


--
-- TOC entry 4641 (class 0 OID 0)
-- Dependencies: 311
-- Name: COLUMN sp_queue_mo.exception; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.sp_queue_mo.exception IS 'Текст ошибки';


--
-- TOC entry 310 (class 1259 OID 570084)
-- Name: sp_queue_mo_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.sp_queue_mo ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.sp_queue_mo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 257 (class 1259 OID 569747)
-- Name: streaming; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.streaming (
    id bigint NOT NULL,
    mdm_id character varying(256) NOT NULL,
    type character varying(50) NOT NULL,
    version integer,
    create_dt timestamp without time zone DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'utc'::text) NOT NULL,
    change_id uuid,
    change_dt timestamp without time zone,
    change_key character varying(2024),
    recheck boolean DEFAULT true NOT NULL,
    recheck_not_before_dt timestamp without time zone,
    error text
);


--
-- TOC entry 4642 (class 0 OID 0)
-- Dependencies: 257
-- Name: TABLE streaming; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.streaming IS 'Информация по стримингу нужных сущностей';


--
-- TOC entry 4643 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.id IS 'Идентификатор';


--
-- TOC entry 4644 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.mdm_id IS 'MDM ID клиента';


--
-- TOC entry 4645 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.type IS 'Тип стриминга';


--
-- TOC entry 4646 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.version; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.version IS 'Версия изменения';


--
-- TOC entry 4647 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.create_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.create_dt IS 'Дата и время создания';


--
-- TOC entry 4648 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.change_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.change_id IS 'Уникальный идентификатор изменения';


--
-- TOC entry 4649 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.change_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.change_dt IS 'Дата и время изменения';


--
-- TOC entry 4650 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.change_key; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.change_key IS 'Ключ изменения';


--
-- TOC entry 4651 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.recheck; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.recheck IS 'Признак проверки необходимости отсылки сообщения в стриминг';


--
-- TOC entry 4652 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.recheck_not_before_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.recheck_not_before_dt IS 'Дата и время изменения';


--
-- TOC entry 4653 (class 0 OID 0)
-- Dependencies: 257
-- Name: COLUMN streaming.error; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming.error IS 'Описание ошибки';


--
-- TOC entry 323 (class 1259 OID 570184)
-- Name: streaming_candidate; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.streaming_candidate (
    id bigint NOT NULL,
    mdm_id character varying(256) NOT NULL,
    date_added timestamp without time zone DEFAULT now() NOT NULL
);


--
-- TOC entry 4654 (class 0 OID 0)
-- Dependencies: 323
-- Name: TABLE streaming_candidate; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.streaming_candidate IS 'Информация по стримингу для клиентов, которых надо простримить заново в озеро даных';


--
-- TOC entry 4655 (class 0 OID 0)
-- Dependencies: 323
-- Name: COLUMN streaming_candidate.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming_candidate.id IS 'Идентификатор';


--
-- TOC entry 4656 (class 0 OID 0)
-- Dependencies: 323
-- Name: COLUMN streaming_candidate.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming_candidate.mdm_id IS 'MDM ID клиента';


--
-- TOC entry 4657 (class 0 OID 0)
-- Dependencies: 323
-- Name: COLUMN streaming_candidate.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.streaming_candidate.date_added IS 'Дата и время создания';


--
-- TOC entry 322 (class 1259 OID 570183)
-- Name: streaming_candidate_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.streaming_candidate ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.streaming_candidate_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 256 (class 1259 OID 569746)
-- Name: streaming_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.streaming ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.streaming_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 309 (class 1259 OID 570054)
-- Name: super_vip_history; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.super_vip_history (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    assign_employee_id bigint,
    unassign_employee_id bigint,
    date_added timestamp without time zone,
    date_revoked timestamp without time zone,
    super_vip boolean GENERATED ALWAYS AS ((date_revoked IS NULL)) STORED
);


--
-- TOC entry 4658 (class 0 OID 0)
-- Dependencies: 309
-- Name: TABLE super_vip_history; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.super_vip_history IS 'История снятия и проставления метки Super-VIP';


--
-- TOC entry 4659 (class 0 OID 0)
-- Dependencies: 309
-- Name: COLUMN super_vip_history.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.super_vip_history.id IS 'Идентификатор';


--
-- TOC entry 4660 (class 0 OID 0)
-- Dependencies: 309
-- Name: COLUMN super_vip_history.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.super_vip_history.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4661 (class 0 OID 0)
-- Dependencies: 309
-- Name: COLUMN super_vip_history.assign_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.super_vip_history.assign_employee_id IS 'Ссылка на сотрудника, который назначил метку Super-VIP';


--
-- TOC entry 4662 (class 0 OID 0)
-- Dependencies: 309
-- Name: COLUMN super_vip_history.unassign_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.super_vip_history.unassign_employee_id IS 'Ссылка на сотрудника, который снял метку Super-VIP';


--
-- TOC entry 4663 (class 0 OID 0)
-- Dependencies: 309
-- Name: COLUMN super_vip_history.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.super_vip_history.date_added IS 'Дата проставления';


--
-- TOC entry 4664 (class 0 OID 0)
-- Dependencies: 309
-- Name: COLUMN super_vip_history.date_revoked; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.super_vip_history.date_revoked IS 'Дата снятия';


--
-- TOC entry 308 (class 1259 OID 570053)
-- Name: super_vip_history_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.super_vip_history ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.super_vip_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 370 (class 1259 OID 946831)
-- Name: tag; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.tag (
    id bigint NOT NULL,
    code character varying(25) NOT NULL,
    name character varying(25) NOT NULL,
    color_scheme character varying(25) NOT NULL
);


--
-- TOC entry 4665 (class 0 OID 0)
-- Dependencies: 370
-- Name: TABLE tag; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.tag IS 'Cправочник тегов';


--
-- TOC entry 4666 (class 0 OID 0)
-- Dependencies: 370
-- Name: COLUMN tag.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tag.id IS 'Идентификатор записи';


--
-- TOC entry 4667 (class 0 OID 0)
-- Dependencies: 370
-- Name: COLUMN tag.code; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tag.code IS 'Код тэга';


--
-- TOC entry 4668 (class 0 OID 0)
-- Dependencies: 370
-- Name: COLUMN tag.name; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tag.name IS 'Наименование тэга';


--
-- TOC entry 4669 (class 0 OID 0)
-- Dependencies: 370
-- Name: COLUMN tag.color_scheme; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tag.color_scheme IS 'Код цветовой схемы';


--
-- TOC entry 369 (class 1259 OID 946830)
-- Name: tag_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.tag ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.tag_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 361 (class 1259 OID 570440)
-- Name: tbcv_vip_prime_apfl_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.tbcv_vip_prime_apfl_queue (
    id bigint NOT NULL,
    mdm_id character varying(50) NOT NULL
);


--
-- TOC entry 4670 (class 0 OID 0)
-- Dependencies: 361
-- Name: TABLE tbcv_vip_prime_apfl_queue; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.tbcv_vip_prime_apfl_queue IS 'Очередь для отправки mdm_id на актуализацию банковских остатков в 1447_16';


--
-- TOC entry 4671 (class 0 OID 0)
-- Dependencies: 361
-- Name: COLUMN tbcv_vip_prime_apfl_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tbcv_vip_prime_apfl_queue.id IS 'Уникальный идентификатор записи';


--
-- TOC entry 4672 (class 0 OID 0)
-- Dependencies: 361
-- Name: COLUMN tbcv_vip_prime_apfl_queue.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tbcv_vip_prime_apfl_queue.mdm_id IS 'mdm_id клиента для актуализации остатков';


--
-- TOC entry 360 (class 1259 OID 570439)
-- Name: tbcv_vip_prime_apfl_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.tbcv_vip_prime_apfl_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.tbcv_vip_prime_apfl_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 241 (class 1259 OID 569593)
-- Name: team_history; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.team_history (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    event_date timestamp without time zone NOT NULL,
    type character varying(50) NOT NULL,
    event character varying(2024) NOT NULL,
    login character varying(50) NOT NULL,
    branch character varying(100),
    extra_login character varying(50)
);


--
-- TOC entry 4673 (class 0 OID 0)
-- Dependencies: 241
-- Name: TABLE team_history; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.team_history IS 'История событий КО';


--
-- TOC entry 4674 (class 0 OID 0)
-- Dependencies: 241
-- Name: COLUMN team_history.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.team_history.id IS 'Идентификатор';


--
-- TOC entry 4675 (class 0 OID 0)
-- Dependencies: 241
-- Name: COLUMN team_history.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.team_history.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4676 (class 0 OID 0)
-- Dependencies: 241
-- Name: COLUMN team_history.event_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.team_history.event_date IS 'Дата события';


--
-- TOC entry 4677 (class 0 OID 0)
-- Dependencies: 241
-- Name: COLUMN team_history.type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.team_history.type IS 'Тип события';


--
-- TOC entry 4678 (class 0 OID 0)
-- Dependencies: 241
-- Name: COLUMN team_history.event; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.team_history.event IS 'Параметры события в json формате';


--
-- TOC entry 4679 (class 0 OID 0)
-- Dependencies: 241
-- Name: COLUMN team_history.login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.team_history.login IS 'Логин сотрудника';


--
-- TOC entry 4680 (class 0 OID 0)
-- Dependencies: 241
-- Name: COLUMN team_history.branch; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.team_history.branch IS 'Внешний код отделения инициатора';


--
-- TOC entry 4681 (class 0 OID 0)
-- Dependencies: 241
-- Name: COLUMN team_history.extra_login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.team_history.extra_login IS 'Логин сотрудника, за которым был закреплён клиент';


--
-- TOC entry 240 (class 1259 OID 569592)
-- Name: team_history_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.team_history ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.team_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 233 (class 1259 OID 569494)
-- Name: temporary_shift; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.temporary_shift (
    id bigint NOT NULL,
    customer_to_employee_id bigint NOT NULL,
    return_employee_id bigint,
    return_date timestamp without time zone,
    return_attempt_date timestamp without time zone,
    state_retry smallint NOT NULL,
    start_date timestamp without time zone NOT NULL,
    reason character varying(500) NOT NULL
);


--
-- TOC entry 4682 (class 0 OID 0)
-- Dependencies: 233
-- Name: TABLE temporary_shift; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.temporary_shift IS 'Временные замещения';


--
-- TOC entry 4683 (class 0 OID 0)
-- Dependencies: 233
-- Name: COLUMN temporary_shift.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift.id IS 'Идентификатор';


--
-- TOC entry 4684 (class 0 OID 0)
-- Dependencies: 233
-- Name: COLUMN temporary_shift.customer_to_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift.customer_to_employee_id IS 'Ссылка на подменяемое закрепление';


--
-- TOC entry 4685 (class 0 OID 0)
-- Dependencies: 233
-- Name: COLUMN temporary_shift.return_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift.return_employee_id IS 'Ссылка на основного сотрудника';


--
-- TOC entry 4686 (class 0 OID 0)
-- Dependencies: 233
-- Name: COLUMN temporary_shift.return_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift.return_date IS 'Дата возвращения';


--
-- TOC entry 4687 (class 0 OID 0)
-- Dependencies: 233
-- Name: COLUMN temporary_shift.return_attempt_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift.return_attempt_date IS 'Последняя дата попытки автовозвращения';


--
-- TOC entry 4688 (class 0 OID 0)
-- Dependencies: 233
-- Name: COLUMN temporary_shift.state_retry; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift.state_retry IS 'Кол-во попыток выполнения';


--
-- TOC entry 4689 (class 0 OID 0)
-- Dependencies: 233
-- Name: COLUMN temporary_shift.start_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift.start_date IS 'Дата начала замещения';


--
-- TOC entry 4690 (class 0 OID 0)
-- Dependencies: 233
-- Name: COLUMN temporary_shift.reason; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift.reason IS 'Причина замещения';


--
-- TOC entry 271 (class 1259 OID 569824)
-- Name: temporary_shift_audit; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.temporary_shift_audit (
    id bigint NOT NULL,
    operation character varying(1) NOT NULL,
    stamp timestamp without time zone NOT NULL,
    userid character varying(64) NOT NULL,
    entity_id bigint NOT NULL,
    customer_to_employee_id bigint,
    return_employee_id bigint,
    return_date timestamp without time zone,
    return_attempt_date timestamp without time zone,
    state_retry smallint,
    start_date timestamp without time zone,
    reason character varying(500)
);


--
-- TOC entry 4691 (class 0 OID 0)
-- Dependencies: 271
-- Name: TABLE temporary_shift_audit; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.temporary_shift_audit IS 'История изменений данных в таблице temporary_shift';


--
-- TOC entry 4692 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.id IS 'Идентификатор';


--
-- TOC entry 4693 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.operation; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.operation IS 'D - Delete, I - Insert, U - Update';


--
-- TOC entry 4694 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.stamp; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.stamp IS 'Дата и время изменения';


--
-- TOC entry 4695 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.userid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.userid IS 'Новое значение';


--
-- TOC entry 4696 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.entity_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.entity_id IS 'Идентификатор изменившейся записи';


--
-- TOC entry 4697 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.customer_to_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.customer_to_employee_id IS 'Ссылка на подменяемое закрепление';


--
-- TOC entry 4698 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.return_employee_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.return_employee_id IS 'Ссылка на основного сотрудника';


--
-- TOC entry 4699 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.return_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.return_date IS 'Дата возвращения';


--
-- TOC entry 4700 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.return_attempt_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.return_attempt_date IS 'Последняя дата попытки автовозвращения';


--
-- TOC entry 4701 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.state_retry; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.state_retry IS 'Кол-во попыток выполнения';


--
-- TOC entry 4702 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.start_date; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.start_date IS 'Дата начала замещения';


--
-- TOC entry 4703 (class 0 OID 0)
-- Dependencies: 271
-- Name: COLUMN temporary_shift_audit.reason; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.temporary_shift_audit.reason IS 'Причина замещения';


--
-- TOC entry 270 (class 1259 OID 569823)
-- Name: temporary_shift_audit_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.temporary_shift_audit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.temporary_shift_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 232 (class 1259 OID 569493)
-- Name: temporary_shift_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.temporary_shift ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.temporary_shift_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 363 (class 1259 OID 570449)
-- Name: tsss_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.tsss_queue (
    id bigint NOT NULL,
    mdm_id character varying(256) NOT NULL,
    type character varying(50) NOT NULL,
    change_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    change_dt timestamp without time zone DEFAULT now() NOT NULL,
    change_key character varying(2024) NOT NULL,
    is_send boolean DEFAULT false NOT NULL,
    last_send_dt timestamp without time zone,
    error text
);


--
-- TOC entry 4704 (class 0 OID 0)
-- Dependencies: 363
-- Name: COLUMN tsss_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tsss_queue.id IS 'Идентификатор записи';


--
-- TOC entry 4705 (class 0 OID 0)
-- Dependencies: 363
-- Name: COLUMN tsss_queue.mdm_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tsss_queue.mdm_id IS 'mdm_id клиента по которому отправляется сообщение';


--
-- TOC entry 4706 (class 0 OID 0)
-- Dependencies: 363
-- Name: COLUMN tsss_queue.type; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tsss_queue.type IS 'Тип отправляемого сообщения';


--
-- TOC entry 4707 (class 0 OID 0)
-- Dependencies: 363
-- Name: COLUMN tsss_queue.change_uuid; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tsss_queue.change_uuid IS 'Уникальный UUID сообщения для отправки';


--
-- TOC entry 4708 (class 0 OID 0)
-- Dependencies: 363
-- Name: COLUMN tsss_queue.change_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tsss_queue.change_dt IS 'Дата и время изменения для отправки в сообщение';


--
-- TOC entry 4709 (class 0 OID 0)
-- Dependencies: 363
-- Name: COLUMN tsss_queue.change_key; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tsss_queue.change_key IS 'Ключ по которому формируется JSON для отправки в kafka';


--
-- TOC entry 4710 (class 0 OID 0)
-- Dependencies: 363
-- Name: COLUMN tsss_queue.is_send; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tsss_queue.is_send IS 'Признак успешной отправки сообщения';


--
-- TOC entry 4711 (class 0 OID 0)
-- Dependencies: 363
-- Name: COLUMN tsss_queue.last_send_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tsss_queue.last_send_dt IS 'Дата и время последней отправки сообщения';


--
-- TOC entry 4712 (class 0 OID 0)
-- Dependencies: 363
-- Name: COLUMN tsss_queue.error; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.tsss_queue.error IS 'Текст ошибки при отправке сообщения';


--
-- TOC entry 362 (class 1259 OID 570448)
-- Name: tsss_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.tsss_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.tsss_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 287 (class 1259 OID 569917)
-- Name: vip_to_fl_queue; Type: TABLE; Schema: sofk_application; Owner: -
--

CREATE TABLE sofk_application.vip_to_fl_queue (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    date_added timestamp without time zone NOT NULL,
    last_send_dt timestamp without time zone,
    response text,
    tries smallint DEFAULT '0'::smallint,
    vip_value boolean NOT NULL,
    login character varying(50)
);


--
-- TOC entry 4713 (class 0 OID 0)
-- Dependencies: 287
-- Name: TABLE vip_to_fl_queue; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON TABLE sofk_application.vip_to_fl_queue IS 'Очередь отправки меток метки VIP в Карточку ФЛ';


--
-- TOC entry 4714 (class 0 OID 0)
-- Dependencies: 287
-- Name: COLUMN vip_to_fl_queue.id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.vip_to_fl_queue.id IS 'Идентификатор';


--
-- TOC entry 4715 (class 0 OID 0)
-- Dependencies: 287
-- Name: COLUMN vip_to_fl_queue.customer_id; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.vip_to_fl_queue.customer_id IS 'Ссылка на клиента';


--
-- TOC entry 4716 (class 0 OID 0)
-- Dependencies: 287
-- Name: COLUMN vip_to_fl_queue.date_added; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.vip_to_fl_queue.date_added IS 'Дата добавления в очередь';


--
-- TOC entry 4717 (class 0 OID 0)
-- Dependencies: 287
-- Name: COLUMN vip_to_fl_queue.last_send_dt; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.vip_to_fl_queue.last_send_dt IS 'Дата последней отправки';


--
-- TOC entry 4718 (class 0 OID 0)
-- Dependencies: 287
-- Name: COLUMN vip_to_fl_queue.response; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.vip_to_fl_queue.response IS 'Ответ от Карточки ФЛ';


--
-- TOC entry 4719 (class 0 OID 0)
-- Dependencies: 287
-- Name: COLUMN vip_to_fl_queue.tries; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.vip_to_fl_queue.tries IS 'Количество попыток';


--
-- TOC entry 4720 (class 0 OID 0)
-- Dependencies: 287
-- Name: COLUMN vip_to_fl_queue.vip_value; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.vip_to_fl_queue.vip_value IS 'Значение метки vip';


--
-- TOC entry 4721 (class 0 OID 0)
-- Dependencies: 287
-- Name: COLUMN vip_to_fl_queue.login; Type: COMMENT; Schema: sofk_application; Owner: -
--

COMMENT ON COLUMN sofk_application.vip_to_fl_queue.login IS 'Логин сотрудника, инициировавшего изменения';


--
-- TOC entry 286 (class 1259 OID 569916)
-- Name: vip_to_fl_queue_id_seq; Type: SEQUENCE; Schema: sofk_application; Owner: -
--

ALTER TABLE sofk_application.vip_to_fl_queue ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME sofk_application.vip_to_fl_queue_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- TOC entry 3858 (class 2606 OID 914771)
-- Name: affiliate_invitation affiliate_invitation_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.affiliate_invitation
    ADD CONSTRAINT affiliate_invitation_pkey PRIMARY KEY (id);


--
-- TOC entry 3700 (class 2606 OID 573008)
-- Name: affiliates_audit affiliates_audit_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.affiliates_audit
    ADD CONSTRAINT affiliates_audit_pkey PRIMARY KEY (id);


--
-- TOC entry 3802 (class 2606 OID 573015)
-- Name: affiliates_history affiliates_history_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.affiliates_history
    ADD CONSTRAINT affiliates_history_pkey PRIMARY KEY (id);


--
-- TOC entry 3676 (class 2606 OID 572998)
-- Name: affiliates affiliates_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.affiliates
    ADD CONSTRAINT affiliates_pkey PRIMARY KEY (id);


--
-- TOC entry 3712 (class 2606 OID 573022)
-- Name: branch_audit branch_audit_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.branch_audit
    ADD CONSTRAINT branch_audit_pkey PRIMARY KEY (id);


--
-- TOC entry 3624 (class 2606 OID 569451)
-- Name: branch branch_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.branch
    ADD CONSTRAINT branch_pkey PRIMARY KEY (id);


--
-- TOC entry 3745 (class 2606 OID 570017)
-- Name: city city_name_key; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.city
    ADD CONSTRAINT city_name_key UNIQUE (name);


--
-- TOC entry 3747 (class 2606 OID 570015)
-- Name: city city_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.city
    ADD CONSTRAINT city_pkey PRIMARY KEY (id);


--
-- TOC entry 3800 (class 2606 OID 570239)
-- Name: company_kind_of_activity company_kind_of_activity_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.company_kind_of_activity
    ADD CONSTRAINT company_kind_of_activity_pkey PRIMARY KEY (id);


--
-- TOC entry 3844 (class 2606 OID 570392)
-- Name: company_lead_archive company_lead_archive_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.company_lead_archive
    ADD CONSTRAINT company_lead_archive_pkey PRIMARY KEY (id);


--
-- TOC entry 3834 (class 2606 OID 570376)
-- Name: company_lead_branch company_lead_branch_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.company_lead_branch
    ADD CONSTRAINT company_lead_branch_pkey PRIMARY KEY (id);


--
-- TOC entry 3840 (class 2606 OID 570384)
-- Name: company_lead company_lead_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.company_lead
    ADD CONSTRAINT company_lead_pkey PRIMARY KEY (id);


--
-- TOC entry 3831 (class 2606 OID 570370)
-- Name: company_lead_status company_lead_status_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.company_lead_status
    ADD CONSTRAINT company_lead_status_pkey PRIMARY KEY (id);


--
-- TOC entry 3788 (class 2606 OID 573031)
-- Name: company company_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.company
    ADD CONSTRAINT company_pkey PRIMARY KEY (id);


--
-- TOC entry 3797 (class 2606 OID 570232)
-- Name: company_segment company_segment_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.company_segment
    ADD CONSTRAINT company_segment_pkey PRIMARY KEY (id);


--
-- TOC entry 3794 (class 2606 OID 570225)
-- Name: company_type company_type_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.company_type
    ADD CONSTRAINT company_type_pkey PRIMARY KEY (id);


--
-- TOC entry 3696 (class 2606 OID 573157)
-- Name: customer_audit customer_audit_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_audit
    ADD CONSTRAINT customer_audit_pkey PRIMARY KEY (id);


--
-- TOC entry 3735 (class 2606 OID 573174)
-- Name: customer_card_access_audit customer_card_access_audit_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_card_access_audit
    ADD CONSTRAINT customer_card_access_audit_pkey PRIMARY KEY (id);


--
-- TOC entry 3749 (class 2606 OID 573181)
-- Name: customer_card_access_branch customer_card_access_branch_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_card_access_branch
    ADD CONSTRAINT customer_card_access_branch_pkey PRIMARY KEY (id);


--
-- TOC entry 3823 (class 2606 OID 570324)
-- Name: customer_card_access_employee customer_card_access_employee_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_card_access_employee
    ADD CONSTRAINT customer_card_access_employee_pkey PRIMARY KEY (id);


--
-- TOC entry 3732 (class 2606 OID 573166)
-- Name: customer_card_access customer_card_access_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_card_access
    ADD CONSTRAINT customer_card_access_pkey PRIMARY KEY (id);


--
-- TOC entry 3751 (class 2606 OID 573188)
-- Name: customer_card_access_request_log customer_card_access_request_log_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_card_access_request_log
    ADD CONSTRAINT customer_card_access_request_log_pkey PRIMARY KEY (id);


--
-- TOC entry 3820 (class 2606 OID 570317)
-- Name: customer_churn_archive customer_churn_archive_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_churn_archive
    ADD CONSTRAINT customer_churn_archive_pkey PRIMARY KEY (id);


--
-- TOC entry 3770 (class 2606 OID 570138)
-- Name: customer_churn_notification customer_churn_notification_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_churn_notification
    ADD CONSTRAINT customer_churn_notification_pkey PRIMARY KEY (id);


--
-- TOC entry 3765 (class 2606 OID 573197)
-- Name: customer_churn customer_churn_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_churn
    ADD CONSTRAINT customer_churn_pkey PRIMARY KEY (id);


--
-- TOC entry 3869 (class 2606 OID 946960)
-- Name: customer_note customer_note_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_note
    ADD CONSTRAINT customer_note_pkey PRIMARY KEY (id);


--
-- TOC entry 3598 (class 2606 OID 573046)
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (id);


--
-- TOC entry 3698 (class 2606 OID 573222)
-- Name: customer_prime_audit customer_prime_audit_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_prime_audit
    ADD CONSTRAINT customer_prime_audit_pkey PRIMARY KEY (id);


--
-- TOC entry 3665 (class 2606 OID 573214)
-- Name: customer_prime customer_prime_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_prime
    ADD CONSTRAINT customer_prime_pkey PRIMARY KEY (id);


--
-- TOC entry 3810 (class 2606 OID 573229)
-- Name: customer_privilege customer_privilege_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_privilege
    ADD CONSTRAINT customer_privilege_pkey PRIMARY KEY (id);


--
-- TOC entry 3790 (class 2606 OID 573239)
-- Name: customer_to_company customer_to_company_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_company
    ADD CONSTRAINT customer_to_company_pkey PRIMARY KEY (id);


--
-- TOC entry 3827 (class 2606 OID 570337)
-- Name: customer_to_deleted_employee customer_to_deleted_employee_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_deleted_employee
    ADD CONSTRAINT customer_to_deleted_employee_pkey PRIMARY KEY (id);


--
-- TOC entry 3702 (class 2606 OID 573269)
-- Name: customer_to_employee_audit customer_to_employee_audit_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_employee_audit
    ADD CONSTRAINT customer_to_employee_audit_pkey PRIMARY KEY (id);


--
-- TOC entry 3609 (class 2606 OID 573247)
-- Name: customer_to_employee customer_to_employee_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_employee
    ADD CONSTRAINT customer_to_employee_pkey PRIMARY KEY (id);


--
-- TOC entry 3866 (class 2606 OID 946941)
-- Name: customer_to_tag customer_to_tag_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_tag
    ADD CONSTRAINT customer_to_tag_pkey PRIMARY KEY (id);


--
-- TOC entry 3596 (class 2606 OID 569398)
-- Name: databasechangeloglock databasechangeloglock_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.databasechangeloglock
    ADD CONSTRAINT databasechangeloglock_pkey PRIMARY KEY (id);


--
-- TOC entry 3741 (class 2606 OID 573276)
-- Name: dedup_backup_service_team dedup_backup_service_team_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.dedup_backup_service_team
    ADD CONSTRAINT dedup_backup_service_team_pkey PRIMARY KEY (id);


--
-- TOC entry 3737 (class 2606 OID 573287)
-- Name: dedup_log dedup_log_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.dedup_log
    ADD CONSTRAINT dedup_log_pkey PRIMARY KEY (id);


--
-- TOC entry 3739 (class 2606 OID 573296)
-- Name: dedup_queue dedup_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.dedup_queue
    ADD CONSTRAINT dedup_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3710 (class 2606 OID 573316)
-- Name: delayed_shift_audit delayed_shift_audit_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.delayed_shift_audit
    ADD CONSTRAINT delayed_shift_audit_pkey PRIMARY KEY (id);


--
-- TOC entry 3645 (class 2606 OID 573305)
-- Name: delayed_shift delayed_shift_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.delayed_shift
    ADD CONSTRAINT delayed_shift_pkey PRIMARY KEY (id);


--
-- TOC entry 3650 (class 2606 OID 573325)
-- Name: disclaimer_milestone disclaimer_milestone_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.disclaimer_milestone
    ADD CONSTRAINT disclaimer_milestone_pkey PRIMARY KEY (id);


--
-- TOC entry 3708 (class 2606 OID 573421)
-- Name: employee_audit employee_audit_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.employee_audit
    ADD CONSTRAINT employee_audit_pkey PRIMARY KEY (id);


--
-- TOC entry 3605 (class 2606 OID 573334)
-- Name: employee employee_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.employee
    ADD CONSTRAINT employee_pkey PRIMARY KEY (id);


--
-- TOC entry 3706 (class 2606 OID 573443)
-- Name: employee_to_branch_audit employee_to_branch_audit_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.employee_to_branch_audit
    ADD CONSTRAINT employee_to_branch_audit_pkey PRIMARY KEY (id);


--
-- TOC entry 3632 (class 2606 OID 573428)
-- Name: employee_to_branch employee_to_branch_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.employee_to_branch
    ADD CONSTRAINT employee_to_branch_pkey PRIMARY KEY (id);


--
-- TOC entry 3861 (class 2606 OID 914790)
-- Name: family_cs_queue family_cs_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.family_cs_queue
    ADD CONSTRAINT family_cs_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3671 (class 2606 OID 569678)
-- Name: group_prime group_prime_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.group_prime
    ADD CONSTRAINT group_prime_pkey PRIMARY KEY (id);


--
-- TOC entry 3804 (class 2606 OID 570262)
-- Name: group_privilege group_privilege_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.group_privilege
    ADD CONSTRAINT group_privilege_pkey PRIMARY KEY (id);


--
-- TOC entry 3813 (class 2606 OID 570278)
-- Name: import_account_manager import_account_manager_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.import_account_manager
    ADD CONSTRAINT import_account_manager_pkey PRIMARY KEY (id);


--
-- TOC entry 3667 (class 2606 OID 569664)
-- Name: import_failed import_failed_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.import_failed
    ADD CONSTRAINT import_failed_pkey PRIMARY KEY (id);


--
-- TOC entry 3729 (class 2606 OID 573452)
-- Name: managing_director_central_office managing_director_central_office_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.managing_director_central_office
    ADD CONSTRAINT managing_director_central_office_pkey PRIMARY KEY (id);


--
-- TOC entry 3725 (class 2606 OID 573460)
-- Name: managing_director_rsk managing_director_rsk_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.managing_director_rsk
    ADD CONSTRAINT managing_director_rsk_pkey PRIMARY KEY (id);


--
-- TOC entry 3818 (class 2606 OID 570286)
-- Name: mark_to_sofk_queue mark_to_sofk_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.mark_to_sofk_queue
    ADD CONSTRAINT mark_to_sofk_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3720 (class 2606 OID 573468)
-- Name: mark_to_uasp_queue mark_to_uasp_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.mark_to_uasp_queue
    ADD CONSTRAINT mark_to_uasp_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3717 (class 2606 OID 569888)
-- Name: mutator_changes mutator_changes_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.mutator_changes
    ADD CONSTRAINT mutator_changes_pkey PRIMARY KEY (id);


--
-- TOC entry 3715 (class 2606 OID 569879)
-- Name: mutators mutators_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.mutators
    ADD CONSTRAINT mutators_pkey PRIMARY KEY (id);


--
-- TOC entry 3643 (class 2606 OID 573490)
-- Name: person_cs_queue person_cs_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.person_cs_queue
    ADD CONSTRAINT person_cs_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3846 (class 2606 OID 570413)
-- Name: potential_customers potential_customers_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.potential_customers
    ADD CONSTRAINT potential_customers_pkey PRIMARY KEY (id);


--
-- TOC entry 3618 (class 2606 OID 573510)
-- Name: processing_log processing_log_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.processing_log
    ADD CONSTRAINT processing_log_pkey PRIMARY KEY (id);


--
-- TOC entry 3682 (class 2606 OID 573522)
-- Name: profile_queue profile_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.profile_queue
    ADD CONSTRAINT profile_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3761 (class 2606 OID 573547)
-- Name: prospect prospect_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.prospect
    ADD CONSTRAINT prospect_pkey PRIMARY KEY (id);


--
-- TOC entry 3774 (class 2606 OID 813157)
-- Name: relative relative_name_unique; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.relative
    ADD CONSTRAINT relative_name_unique UNIQUE (name);


--
-- TOC entry 3776 (class 2606 OID 573555)
-- Name: relative relative_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.relative
    ADD CONSTRAINT relative_pkey PRIMARY KEY (id);


--
-- TOC entry 3684 (class 2606 OID 573567)
-- Name: rst_group rst_group_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.rst_group
    ADD CONSTRAINT rst_group_pkey PRIMARY KEY (id);


--
-- TOC entry 3660 (class 2606 OID 569625)
-- Name: service_team_import_status service_team_import_status_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.service_team_import_status
    ADD CONSTRAINT service_team_import_status_pkey PRIMARY KEY (id);


--
-- TOC entry 3781 (class 2606 OID 573589)
-- Name: service_team_queue service_team_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.service_team_queue
    ADD CONSTRAINT service_team_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3692 (class 2606 OID 572960)
-- Name: sp_log sp_log_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.sp_log
    ADD CONSTRAINT sp_log_pkey PRIMARY KEY (id);


--
-- TOC entry 3759 (class 2606 OID 572976)
-- Name: sp_queue_mo sp_queue_mo_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.sp_queue_mo
    ADD CONSTRAINT sp_queue_mo_pkey PRIMARY KEY (id);


--
-- TOC entry 3694 (class 2606 OID 573602)
-- Name: sp_queue sp_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.sp_queue
    ADD CONSTRAINT sp_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3785 (class 2606 OID 573622)
-- Name: streaming_candidate streaming_candidate_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.streaming_candidate
    ADD CONSTRAINT streaming_candidate_pkey PRIMARY KEY (id);


--
-- TOC entry 3687 (class 2606 OID 573611)
-- Name: streaming streaming_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.streaming
    ADD CONSTRAINT streaming_pkey PRIMARY KEY (id);


--
-- TOC entry 3755 (class 2606 OID 573630)
-- Name: super_vip_history super_vip_history_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.super_vip_history
    ADD CONSTRAINT super_vip_history_pkey PRIMARY KEY (id);


--
-- TOC entry 3864 (class 2606 OID 946835)
-- Name: tag tag_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.tag
    ADD CONSTRAINT tag_pkey PRIMARY KEY (id);


--
-- TOC entry 3848 (class 2606 OID 570446)
-- Name: tbcv_vip_prime_apfl_queue tbcv_vip_prime_apfl_queue_mdm_id_key; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.tbcv_vip_prime_apfl_queue
    ADD CONSTRAINT tbcv_vip_prime_apfl_queue_mdm_id_key UNIQUE (mdm_id);


--
-- TOC entry 3850 (class 2606 OID 570444)
-- Name: tbcv_vip_prime_apfl_queue tbcv_vip_prime_apfl_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.tbcv_vip_prime_apfl_queue
    ADD CONSTRAINT tbcv_vip_prime_apfl_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3656 (class 2606 OID 572985)
-- Name: team_history team_history_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.team_history
    ADD CONSTRAINT team_history_pkey PRIMARY KEY (id);


--
-- TOC entry 3704 (class 2606 OID 573651)
-- Name: temporary_shift_audit temporary_shift_audit_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.temporary_shift_audit
    ADD CONSTRAINT temporary_shift_audit_pkey PRIMARY KEY (id);


--
-- TOC entry 3639 (class 2606 OID 573640)
-- Name: temporary_shift temporary_shift_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.temporary_shift
    ADD CONSTRAINT temporary_shift_pkey PRIMARY KEY (id);


--
-- TOC entry 3853 (class 2606 OID 570460)
-- Name: tsss_queue tsss_queue_change_uuid_key; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.tsss_queue
    ADD CONSTRAINT tsss_queue_change_uuid_key UNIQUE (change_uuid);


--
-- TOC entry 3856 (class 2606 OID 570458)
-- Name: tsss_queue tsss_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.tsss_queue
    ADD CONSTRAINT tsss_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3627 (class 2606 OID 569453)
-- Name: branch unq_branch_ext_code; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.branch
    ADD CONSTRAINT unq_branch_ext_code UNIQUE (ext_code);


--
-- TOC entry 3648 (class 2606 OID 569614)
-- Name: delayed_shift unq_ds_cust2emp; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.delayed_shift
    ADD CONSTRAINT unq_ds_cust2emp UNIQUE (customer_to_employee_id);


--
-- TOC entry 3727 (class 2606 OID 569948)
-- Name: managing_director_rsk unq_employee_branch; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.managing_director_rsk
    ADD CONSTRAINT unq_employee_branch UNIQUE (employee_id, branch_id);


--
-- TOC entry 3636 (class 2606 OID 569472)
-- Name: employee_to_branch unq_employee_in_branch; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.employee_to_branch
    ADD CONSTRAINT unq_employee_in_branch UNIQUE (branch_id, employee_id);


--
-- TOC entry 3806 (class 2606 OID 570306)
-- Name: group_privilege unq_group_privilege_name; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.group_privilege
    ADD CONSTRAINT unq_group_privilege_name UNIQUE (name);


--
-- TOC entry 3669 (class 2606 OID 569666)
-- Name: import_failed unq_if_mdm_id; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.import_failed
    ADD CONSTRAINT unq_if_mdm_id UNIQUE (mdm_id);


--
-- TOC entry 3842 (class 2606 OID 570394)
-- Name: company_lead unq_lead_id; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.company_lead
    ADD CONSTRAINT unq_lead_id UNIQUE (lead_id);


--
-- TOC entry 3621 (class 2606 OID 569443)
-- Name: processing_log unq_log_process_id; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.processing_log
    ADD CONSTRAINT unq_log_process_id UNIQUE (process_id);


--
-- TOC entry 3601 (class 2606 OID 569406)
-- Name: customer unq_mdm_id; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer
    ADD CONSTRAINT unq_mdm_id UNIQUE (mdm_id);


--
-- TOC entry 3673 (class 2606 OID 569680)
-- Name: group_prime unq_name; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.group_prime
    ADD CONSTRAINT unq_name UNIQUE (name);


--
-- TOC entry 3763 (class 2606 OID 570107)
-- Name: prospect unq_prospect_customer_id; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.prospect
    ADD CONSTRAINT unq_prospect_customer_id UNIQUE (customer_id);


--
-- TOC entry 3615 (class 2606 OID 569668)
-- Name: customer_to_employee unq_role_in_team_id; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_employee
    ADD CONSTRAINT unq_role_in_team_id UNIQUE (customer_id, role_in_team);


--
-- TOC entry 3662 (class 2606 OID 569632)
-- Name: service_team_import_status unq_sti_mdm_id; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.service_team_import_status
    ADD CONSTRAINT unq_sti_mdm_id UNIQUE (mdm_id);


--
-- TOC entry 3757 (class 2606 OID 570075)
-- Name: super_vip_history unq_super_vip_history_id; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.super_vip_history
    ADD CONSTRAINT unq_super_vip_history_id UNIQUE (customer_id, date_added, date_revoked);


--
-- TOC entry 3641 (class 2606 OID 569548)
-- Name: temporary_shift unq_ts_cust2emp; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.temporary_shift
    ADD CONSTRAINT unq_ts_cust2emp UNIQUE (customer_to_employee_id);


--
-- TOC entry 3723 (class 2606 OID 573660)
-- Name: vip_to_fl_queue vip_to_fl_queue_pkey; Type: CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.vip_to_fl_queue
    ADD CONSTRAINT vip_to_fl_queue_pkey PRIMARY KEY (id);


--
-- TOC entry 3674 (class 1259 OID 570272)
-- Name: affiliates_approved_end_dt_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX affiliates_approved_end_dt_index ON sofk_application.affiliates USING btree (approved, end_dt);


--
-- TOC entry 3622 (class 1259 OID 569617)
-- Name: branch_name_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX branch_name_idx ON sofk_application.branch USING btree (name);


--
-- TOC entry 3786 (class 1259 OID 570201)
-- Name: company_inn_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX company_inn_idx ON sofk_application.company USING btree (inn);


--
-- TOC entry 3798 (class 1259 OID 570240)
-- Name: company_kind_of_activity_ext_code_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX company_kind_of_activity_ext_code_index ON sofk_application.company_kind_of_activity USING btree (ext_code);


--
-- TOC entry 3835 (class 1259 OID 570400)
-- Name: company_lead_appointed_branch_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX company_lead_appointed_branch_idx ON sofk_application.company_lead USING btree (appointed_branch_ext_code);


--
-- TOC entry 3832 (class 1259 OID 570399)
-- Name: company_lead_branch_ext_code_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX company_lead_branch_ext_code_idx ON sofk_application.company_lead_branch USING btree (ext_code);


--
-- TOC entry 3836 (class 1259 OID 570395)
-- Name: company_lead_creation_date_inx_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX company_lead_creation_date_inx_idx ON sofk_application.company_lead USING btree (creation_date);


--
-- TOC entry 3837 (class 1259 OID 570396)
-- Name: company_lead_creator_dates_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX company_lead_creator_dates_idx ON sofk_application.company_lead USING btree (creator_employee_pers_num, ((creation_date)::date), ((close_date)::date));


--
-- TOC entry 3838 (class 1259 OID 570397)
-- Name: company_lead_inn_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX company_lead_inn_idx ON sofk_application.company_lead USING btree (company_inn);


--
-- TOC entry 3829 (class 1259 OID 570398)
-- Name: company_lead_status_code_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX company_lead_status_code_idx ON sofk_application.company_lead_status USING btree (code);


--
-- TOC entry 3795 (class 1259 OID 570233)
-- Name: company_segment_ext_code_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX company_segment_ext_code_index ON sofk_application.company_segment USING btree (ext_code);


--
-- TOC entry 3792 (class 1259 OID 570226)
-- Name: company_type_ext_code_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX company_type_ext_code_index ON sofk_application.company_type USING btree (ext_code);


--
-- TOC entry 3663 (class 1259 OID 569716)
-- Name: cp_customer_id_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX cp_customer_id_idx ON sofk_application.customer_prime USING btree (customer_id);


--
-- TOC entry 3807 (class 1259 OID 570271)
-- Name: customer_privilege_customer_id_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX customer_privilege_customer_id_index ON sofk_application.customer_privilege USING btree (customer_id);


--
-- TOC entry 3808 (class 1259 OID 570270)
-- Name: customer_privilege_group_id_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX customer_privilege_group_id_index ON sofk_application.customer_privilege USING btree (group_id);


--
-- TOC entry 3811 (class 1259 OID 570269)
-- Name: customer_privilege_privilege_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX customer_privilege_privilege_index ON sofk_application.customer_privilege USING btree (privilege);


--
-- TOC entry 3791 (class 1259 OID 570219)
-- Name: customer_to_company_unq_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX customer_to_company_unq_idx ON sofk_application.customer_to_company USING btree (customer_id, company_id);


--
-- TOC entry 3824 (class 1259 OID 570360)
-- Name: customer_to_deleted_employee_branch_id_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX customer_to_deleted_employee_branch_id_idx ON sofk_application.customer_to_deleted_employee USING btree (branch_id);


--
-- TOC entry 3825 (class 1259 OID 570362)
-- Name: customer_to_deleted_employee_employee_id_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX customer_to_deleted_employee_employee_id_idx ON sofk_application.customer_to_deleted_employee USING btree (employee_id);


--
-- TOC entry 3828 (class 1259 OID 570361)
-- Name: customer_to_deleted_employee_role_in_team_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX customer_to_deleted_employee_role_in_team_idx ON sofk_application.customer_to_deleted_employee USING btree (role_in_team);


--
-- TOC entry 3607 (class 1259 OID 569732)
-- Name: customer_to_employee_branch_id_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX customer_to_employee_branch_id_idx ON sofk_application.customer_to_employee USING btree (branch_id, role_in_team);


--
-- TOC entry 3610 (class 1259 OID 569733)
-- Name: customer_to_employee_shifter_id_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX customer_to_employee_shifter_id_idx ON sofk_application.customer_to_employee USING btree (shifter_id);


--
-- TOC entry 3651 (class 1259 OID 570246)
-- Name: dm_emp_type_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX dm_emp_type_idx ON sofk_application.disclaimer_milestone USING btree (employee_id, type, role_in_team);


--
-- TOC entry 3628 (class 1259 OID 569713)
-- Name: e2b_department_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX e2b_department_idx ON sofk_application.employee_to_branch USING gin (department);


--
-- TOC entry 3629 (class 1259 OID 569714)
-- Name: e2b_next_act_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX e2b_next_act_idx ON sofk_application.employee_to_branch USING btree (next_actualization_at);


--
-- TOC entry 3602 (class 1259 OID 569669)
-- Name: emp_login_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX emp_login_idx ON sofk_application.employee USING btree (login);


--
-- TOC entry 3603 (class 1259 OID 569670)
-- Name: emp_pers_num_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX emp_pers_num_idx ON sofk_application.employee USING btree (pers_num);


--
-- TOC entry 3630 (class 1259 OID 570241)
-- Name: employee_to_branch_delete_delete_dt_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX employee_to_branch_delete_delete_dt_index ON sofk_application.employee_to_branch USING btree (delete, delete_dt) WHERE (delete IS TRUE);


--
-- TOC entry 3633 (class 1259 OID 569745)
-- Name: employee_to_branch_rst_group_id_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX employee_to_branch_rst_group_id_idx ON sofk_application.employee_to_branch USING btree (rst_group_id);


--
-- TOC entry 3634 (class 1259 OID 570401)
-- Name: etb_employee_id_default_branch_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX etb_employee_id_default_branch_idx ON sofk_application.employee_to_branch USING btree (employee_id, default_branch);


--
-- TOC entry 3677 (class 1259 OID 569703)
-- Name: idx_aff_cust_affiliate; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_aff_cust_affiliate ON sofk_application.affiliates USING btree (affiliate_id);


--
-- TOC entry 3678 (class 1259 OID 569702)
-- Name: idx_aff_cust_master; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_aff_cust_master ON sofk_application.affiliates USING btree (master_id);


--
-- TOC entry 3859 (class 1259 OID 914782)
-- Name: idx_affiliate_invitation_create_dt_approved; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_affiliate_invitation_create_dt_approved ON sofk_application.affiliate_invitation USING btree (create_dt) WHERE (approved IS NOT NULL);


--
-- TOC entry 3625 (class 1259 OID 570023)
-- Name: idx_branch2city; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_branch2city ON sofk_application.branch USING btree (city_id);


--
-- TOC entry 3611 (class 1259 OID 570447)
-- Name: idx_c2e_assigned_date; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_c2e_assigned_date ON sofk_application.customer_to_employee USING btree (assigned_date);


--
-- TOC entry 3612 (class 1259 OID 569435)
-- Name: idx_c2e_employee_id; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_c2e_employee_id ON sofk_application.customer_to_employee USING btree (service_team_member_id);


--
-- TOC entry 3771 (class 1259 OID 570149)
-- Name: idx_ccn_customer_churn_id; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_ccn_customer_churn_id ON sofk_application.customer_churn_notification USING btree (customer_churn_id);


--
-- TOC entry 3772 (class 1259 OID 570150)
-- Name: idx_ccn_customer_employee_id; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_ccn_customer_employee_id ON sofk_application.customer_churn_notification USING btree (employee_id);


--
-- TOC entry 3821 (class 1259 OID 570318)
-- Name: idx_customer_churn_archive_event_date; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_customer_churn_archive_event_date ON sofk_application.customer_churn_archive USING btree (event_date);


--
-- TOC entry 3766 (class 1259 OID 570131)
-- Name: idx_customer_churn_customer_id; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_customer_churn_customer_id ON sofk_application.customer_churn USING btree (customer_id);


--
-- TOC entry 3767 (class 1259 OID 570171)
-- Name: idx_customer_churn_total; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_customer_churn_total ON sofk_application.customer_churn USING btree (old_employee_role, old_customer_branch_id, old_employee_id);


--
-- TOC entry 3599 (class 1259 OID 570159)
-- Name: idx_customer_fio; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_customer_fio ON sofk_application.customer USING btree (fio varchar_pattern_ops);


--
-- TOC entry 3733 (class 1259 OID 569972)
-- Name: idx_customer_id; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX idx_customer_id ON sofk_application.customer_card_access USING btree (customer_id);


--
-- TOC entry 3768 (class 1259 OID 570132)
-- Name: idx_customer_initiator_id; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_customer_initiator_id ON sofk_application.customer_churn USING btree (initiator_id);


--
-- TOC entry 3867 (class 1259 OID 946952)
-- Name: idx_customer_tag_customer_tag; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_customer_tag_customer_tag ON sofk_application.customer_to_tag USING btree (potential_customer_id, tag_id);


--
-- TOC entry 3777 (class 1259 OID 570330)
-- Name: idx_date_added; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_date_added ON sofk_application.service_team_queue USING btree (date_added);


--
-- TOC entry 3613 (class 1259 OID 813115)
-- Name: idx_date_func_from_c2e_assigned_date; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_date_func_from_c2e_assigned_date ON sofk_application.customer_to_employee USING btree (date(assigned_date));


--
-- TOC entry 3742 (class 1259 OID 570008)
-- Name: idx_dedup_backup_service_team_customer_mdm_id; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_dedup_backup_service_team_customer_mdm_id ON sofk_application.dedup_backup_service_team USING btree (customer_mdm_id);


--
-- TOC entry 3743 (class 1259 OID 570009)
-- Name: idx_dedup_backup_service_team_new_customer_mdm_id; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_dedup_backup_service_team_new_customer_mdm_id ON sofk_application.dedup_backup_service_team USING btree (new_customer_mdm_id);


--
-- TOC entry 3652 (class 1259 OID 569569)
-- Name: idx_dm_employee; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_dm_employee ON sofk_application.disclaimer_milestone USING btree (employee_id);


--
-- TOC entry 3646 (class 1259 OID 569544)
-- Name: idx_ds_shift_date; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_ds_shift_date ON sofk_application.delayed_shift USING btree (shift_date);


--
-- TOC entry 3606 (class 1259 OID 914802)
-- Name: idx_employee_fio; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_employee_fio ON sofk_application.employee USING btree (fio);


--
-- TOC entry 3862 (class 1259 OID 914791)
-- Name: idx_family_cs_queue_date_executed; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_family_cs_queue_date_executed ON sofk_application.family_cs_queue USING btree (date_executed);


--
-- TOC entry 3713 (class 1259 OID 569880)
-- Name: idx_mutators_unq; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_mutators_unq ON sofk_application.mutators USING btree (mutator_type, name);


--
-- TOC entry 3752 (class 1259 OID 570082)
-- Name: idx_super_vip_history_customer_id; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_super_vip_history_customer_id ON sofk_application.super_vip_history USING btree (customer_id);


--
-- TOC entry 3753 (class 1259 OID 570083)
-- Name: idx_super_vip_history_employee_id; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_super_vip_history_employee_id ON sofk_application.super_vip_history USING btree (assign_employee_id);


--
-- TOC entry 3637 (class 1259 OID 569510)
-- Name: idx_ts_return_date; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_ts_return_date ON sofk_application.temporary_shift USING btree (return_date);


--
-- TOC entry 3851 (class 1259 OID 698497)
-- Name: idx_tsss_queue_change_dt_is_send; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX idx_tsss_queue_change_dt_is_send ON sofk_application.tsss_queue USING btree (change_dt, is_send);


--
-- TOC entry 3814 (class 1259 OID 698498)
-- Name: m2sofk_queue_customer_id_and_status_idx_and_mark_type; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX m2sofk_queue_customer_id_and_status_idx_and_mark_type ON sofk_application.mark_to_sofk_queue USING btree (customer_id, status, mark_type);


--
-- TOC entry 3815 (class 1259 OID 570294)
-- Name: m2sofk_queue_date_added_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX m2sofk_queue_date_added_idx ON sofk_application.mark_to_sofk_queue USING btree (date_added);


--
-- TOC entry 3816 (class 1259 OID 570292)
-- Name: m2sofk_queue_last_sent_and_status_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX m2sofk_queue_last_sent_and_status_idx ON sofk_application.mark_to_sofk_queue USING btree (last_sent_dt, status);


--
-- TOC entry 3718 (class 1259 OID 569915)
-- Name: m2uasp_queue_executed_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX m2uasp_queue_executed_idx ON sofk_application.mark_to_uasp_queue USING btree (last_send_dt);


--
-- TOC entry 3730 (class 1259 OID 569960)
-- Name: mdco_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX mdco_idx ON sofk_application.managing_director_central_office USING btree (employee_id);


--
-- TOC entry 3679 (class 1259 OID 573531)
-- Name: pq_customer_id_unq_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE UNIQUE INDEX pq_customer_id_unq_idx ON sofk_application.profile_queue USING btree (customer_id);


--
-- TOC entry 3680 (class 1259 OID 569779)
-- Name: pq_date_executed_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX pq_date_executed_idx ON sofk_application.profile_queue USING btree (date_executed);


--
-- TOC entry 3616 (class 1259 OID 569444)
-- Name: processing_log_period_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX processing_log_period_idx ON sofk_application.processing_log USING btree (process_start, process_end);


--
-- TOC entry 3619 (class 1259 OID 569445)
-- Name: processing_log_state_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX processing_log_state_idx ON sofk_application.processing_log USING btree (state);


--
-- TOC entry 3778 (class 1259 OID 570181)
-- Name: service_team_queue_last_sent_dt_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX service_team_queue_last_sent_dt_index ON sofk_application.service_team_queue USING btree (last_send_dt);


--
-- TOC entry 3779 (class 1259 OID 570182)
-- Name: service_team_queue_mdm_id_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX service_team_queue_mdm_id_index ON sofk_application.service_team_queue USING btree (mdm_id);


--
-- TOC entry 3782 (class 1259 OID 570180)
-- Name: service_team_queue_status_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX service_team_queue_status_index ON sofk_application.service_team_queue USING btree (status);


--
-- TOC entry 3689 (class 1259 OID 570192)
-- Name: sp_log_dt_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX sp_log_dt_index ON sofk_application.sp_log USING btree (dt);


--
-- TOC entry 3690 (class 1259 OID 569766)
-- Name: sp_log_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX sp_log_idx ON sofk_application.sp_log USING btree (mdm_id);


--
-- TOC entry 3783 (class 1259 OID 570190)
-- Name: streaming_candidate_date_added_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX streaming_candidate_date_added_idx ON sofk_application.streaming_candidate USING btree (date_added);


--
-- TOC entry 3685 (class 1259 OID 569894)
-- Name: streaming_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX streaming_idx ON sofk_application.streaming USING btree (mdm_id, type);


--
-- TOC entry 3688 (class 1259 OID 569895)
-- Name: streaming_process_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX streaming_process_idx ON sofk_application.streaming USING btree (version, recheck_not_before_dt) WHERE (version IS NULL);


--
-- TOC entry 3653 (class 1259 OID 569633)
-- Name: team_history_customer_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX team_history_customer_idx ON sofk_application.team_history USING btree (customer_id, event_date DESC);


--
-- TOC entry 3654 (class 1259 OID 570191)
-- Name: team_history_index; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX team_history_index ON sofk_application.team_history USING hash (type) WHERE ((type)::text = ANY ((ARRAY['SUPERVIP_LABEL_SET'::character varying, 'SUPERVIP_LABEL_REVOKED'::character varying, 'DEDUPLICATION'::character varying, 'DE_DEDUPLICATION'::character varying, 'SET_NEW_MDM'::character varying])::text[]));


--
-- TOC entry 3657 (class 1259 OID 569717)
-- Name: th_ex_login_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX th_ex_login_idx ON sofk_application.team_history USING btree (extra_login);


--
-- TOC entry 3658 (class 1259 OID 569619)
-- Name: th_login_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX th_login_idx ON sofk_application.team_history USING btree (login);


--
-- TOC entry 3854 (class 1259 OID 570461)
-- Name: tsss_queue_mdm_type; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX tsss_queue_mdm_type ON sofk_application.tsss_queue USING btree (mdm_id, type);


--
-- TOC entry 3721 (class 1259 OID 569929)
-- Name: vip2fl_queue_executed_idx; Type: INDEX; Schema: sofk_application; Owner: -
--

CREATE INDEX vip2fl_queue_executed_idx ON sofk_application.vip_to_fl_queue USING btree (last_send_dt);


--
-- TOC entry 3953 (class 2620 OID 569814)
-- Name: affiliates affiliates_audit_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER affiliates_audit_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.affiliates FOR EACH ROW EXECUTE FUNCTION sofk_application.process_affiliates_audit();


--
-- TOC entry 3954 (class 2620 OID 570254)
-- Name: affiliates affiliates_history_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER affiliates_history_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.affiliates FOR EACH ROW EXECUTE FUNCTION sofk_application.process_affiliates_history();


--
-- TOC entry 3930 (class 2620 OID 570467)
-- Name: customer after_delete_customer_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_delete_customer_to_tsss_queue AFTER DELETE ON sofk_application.customer FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_customer_delete_tsss_queue();


--
-- TOC entry 3955 (class 2620 OID 570483)
-- Name: affiliates after_insert_delete_affiliates_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_insert_delete_affiliates_to_tsss_queue AFTER INSERT OR DELETE ON sofk_application.affiliates FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_affiliates_insert_delete_tsss_queue();


--
-- TOC entry 3948 (class 2620 OID 570473)
-- Name: customer_prime after_insert_delete_customer_prime_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_insert_delete_customer_prime_to_tsss_queue AFTER INSERT OR DELETE ON sofk_application.customer_prime FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_customer_prime_insert_delete_tsss_queue();


--
-- TOC entry 3959 (class 2620 OID 570479)
-- Name: super_vip_history after_insert_delete_svh_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_insert_delete_svh_to_tsss_queue AFTER INSERT OR DELETE ON sofk_application.super_vip_history FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_svh_insert_delete_tsss_queue();


--
-- TOC entry 3945 (class 2620 OID 570495)
-- Name: temporary_shift after_insert_temporary_shift_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_insert_temporary_shift_to_tsss_queue AFTER INSERT ON sofk_application.temporary_shift FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_temporary_shift_insert_tsss_queue();


--
-- TOC entry 3937 (class 2620 OID 570471)
-- Name: customer_to_employee after_insert_update_delete_cte_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_insert_update_delete_cte_to_tsss_queue AFTER INSERT OR DELETE OR UPDATE ON sofk_application.customer_to_employee FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_cte_insert_update_delete_tsss_queue();


--
-- TOC entry 3956 (class 2620 OID 570485)
-- Name: affiliates after_update_affiliates_relative_id_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_update_affiliates_relative_id_to_tsss_queue AFTER UPDATE OF relative_id ON sofk_application.affiliates FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_affiliates_update_relative_id_tsss_queue();


--
-- TOC entry 3931 (class 2620 OID 570469)
-- Name: customer after_update_customer_mdm_id_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_update_customer_mdm_id_to_tsss_queue AFTER UPDATE OF mdm_id ON sofk_application.customer FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_customer_update_mdm_id_tsss_queue();


--
-- TOC entry 3949 (class 2620 OID 570477)
-- Name: customer_prime after_update_customer_prime_group_id_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_update_customer_prime_group_id_to_tsss_queue AFTER UPDATE OF group_id ON sofk_application.customer_prime FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_customer_prime_update_group_id_tsss_queue();


--
-- TOC entry 3950 (class 2620 OID 570475)
-- Name: customer_prime after_update_customer_prime_vip_top_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_update_customer_prime_vip_top_to_tsss_queue AFTER UPDATE OF vip, top ON sofk_application.customer_prime FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_customer_prime_update_vip_top_tsss_queue();


--
-- TOC entry 3960 (class 2620 OID 570481)
-- Name: super_vip_history after_update_svh_super_vip_to_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER after_update_svh_super_vip_to_tsss_queue AFTER UPDATE OF super_vip ON sofk_application.super_vip_history FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_svh_update_super_vip_tsss_queue();


--
-- TOC entry 3943 (class 2620 OID 569870)
-- Name: branch branch_audit_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER branch_audit_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.branch FOR EACH ROW EXECUTE FUNCTION sofk_application.process_branch_audit();


--
-- TOC entry 3932 (class 2620 OID 570438)
-- Name: customer customer_audit_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER customer_audit_tg AFTER INSERT OR DELETE OR UPDATE OF mdm_id, first_name, last_name, middle_name, service_pack, ex_ob ON sofk_application.customer FOR EACH ROW EXECUTE FUNCTION sofk_application.process_customer_audit();


--
-- TOC entry 3958 (class 2620 OID 569980)
-- Name: customer_card_access customer_card_access_audit_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER customer_card_access_audit_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.customer_card_access FOR EACH ROW EXECUTE FUNCTION sofk_application.process_customer_card_access_audit();


--
-- TOC entry 3951 (class 2620 OID 569806)
-- Name: customer_prime customer_prime_audit_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER customer_prime_audit_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.customer_prime FOR EACH ROW EXECUTE FUNCTION sofk_application.process_customer_prime_audit();


--
-- TOC entry 3938 (class 2620 OID 570406)
-- Name: customer_to_employee customer_to_employee_assigned_date_on_rm_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER customer_to_employee_assigned_date_on_rm_tg AFTER DELETE ON sofk_application.customer_to_employee FOR EACH ROW EXECUTE FUNCTION sofk_application.customer_to_employee_assigned_date_on_rm();


--
-- TOC entry 3939 (class 2620 OID 570405)
-- Name: customer_to_employee customer_to_employee_assigned_date_on_upd_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER customer_to_employee_assigned_date_on_upd_tg AFTER INSERT OR UPDATE OF service_team_member_id ON sofk_application.customer_to_employee FOR EACH ROW EXECUTE FUNCTION sofk_application.customer_to_employee_assigned_date_on_upd();


--
-- TOC entry 3940 (class 2620 OID 569822)
-- Name: customer_to_employee customer_to_employee_audit_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER customer_to_employee_audit_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.customer_to_employee FOR EACH ROW EXECUTE FUNCTION sofk_application.process_customer_to_employee_audit();


--
-- TOC entry 3941 (class 2620 OID 570359)
-- Name: customer_to_employee customer_to_employee_deleted_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER customer_to_employee_deleted_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.customer_to_employee FOR EACH ROW EXECUTE FUNCTION sofk_application.process_customer_to_deleted_employee();


--
-- TOC entry 3947 (class 2620 OID 569860)
-- Name: delayed_shift delayed_shift_audit_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER delayed_shift_audit_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.delayed_shift FOR EACH ROW EXECUTE FUNCTION sofk_application.process_delayed_shift_audit();


--
-- TOC entry 3936 (class 2620 OID 569850)
-- Name: employee employee_audit_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER employee_audit_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.employee FOR EACH ROW EXECUTE FUNCTION sofk_application.process_employee_audit();


--
-- TOC entry 3944 (class 2620 OID 569842)
-- Name: employee_to_branch employee_to_branch_audit_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER employee_to_branch_audit_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.employee_to_branch FOR EACH ROW EXECUTE FUNCTION sofk_application.process_employee_to_branch_audit();


--
-- TOC entry 3933 (class 2620 OID 813155)
-- Name: customer set_customer_service_pack_default; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER set_customer_service_pack_default BEFORE INSERT OR UPDATE ON sofk_application.customer FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_set_customer_default_service_pack();


--
-- TOC entry 3946 (class 2620 OID 569832)
-- Name: temporary_shift temporary_shift_audit_tg; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER temporary_shift_audit_tg AFTER INSERT OR DELETE OR UPDATE ON sofk_application.temporary_shift FOR EACH ROW EXECUTE FUNCTION sofk_application.process_temporary_shift_audit();


--
-- TOC entry 3934 (class 2620 OID 570465)
-- Name: customer tr_customer_insert_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER tr_customer_insert_tsss_queue AFTER INSERT ON sofk_application.customer FOR EACH ROW EXECUTE FUNCTION sofk_application.after_insert_customer_to_tsss_queue();


--
-- TOC entry 3962 (class 2620 OID 570487)
-- Name: tsss_queue trg_before_insert_tsss_queue; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER trg_before_insert_tsss_queue BEFORE INSERT ON sofk_application.tsss_queue FOR EACH ROW EXECUTE FUNCTION sofk_application.trg_tsss_queue_check_last();


--
-- TOC entry 3957 (class 2620 OID 570492)
-- Name: affiliates trg_forbid_update_affiliates_master_id_affiliate_id; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER trg_forbid_update_affiliates_master_id_affiliate_id BEFORE UPDATE ON sofk_application.affiliates FOR EACH ROW EXECUTE FUNCTION sofk_application.forbid_update_customer_id();


--
-- TOC entry 3942 (class 2620 OID 570489)
-- Name: customer_to_employee trg_forbid_update_cte_customer_id; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER trg_forbid_update_cte_customer_id BEFORE UPDATE ON sofk_application.customer_to_employee FOR EACH ROW EXECUTE FUNCTION sofk_application.forbid_update_customer_id();


--
-- TOC entry 3935 (class 2620 OID 570493)
-- Name: customer trg_forbid_update_customer_id; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER trg_forbid_update_customer_id BEFORE UPDATE ON sofk_application.customer FOR EACH ROW EXECUTE FUNCTION sofk_application.forbid_update_customer_id();


--
-- TOC entry 3952 (class 2620 OID 570490)
-- Name: customer_prime trg_forbid_update_customer_prime_customer_id; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER trg_forbid_update_customer_prime_customer_id BEFORE UPDATE ON sofk_application.customer_prime FOR EACH ROW EXECUTE FUNCTION sofk_application.forbid_update_customer_id();


--
-- TOC entry 3961 (class 2620 OID 570491)
-- Name: super_vip_history trg_forbid_update_svh_customer_id; Type: TRIGGER; Schema: sofk_application; Owner: -
--

CREATE TRIGGER trg_forbid_update_svh_customer_id BEFORE UPDATE ON sofk_application.super_vip_history FOR EACH ROW EXECUTE FUNCTION sofk_application.forbid_update_customer_id();


--
-- TOC entry 3888 (class 2606 OID 573072)
-- Name: affiliates fk_aff_cust_affiliate; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.affiliates
    ADD CONSTRAINT fk_aff_cust_affiliate FOREIGN KEY (affiliate_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3889 (class 2606 OID 573067)
-- Name: affiliates fk_aff_cust_master; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.affiliates
    ADD CONSTRAINT fk_aff_cust_master FOREIGN KEY (master_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3925 (class 2606 OID 914772)
-- Name: affiliate_invitation fk_affinv_affiliate; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.affiliate_invitation
    ADD CONSTRAINT fk_affinv_affiliate FOREIGN KEY (affiliate_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3926 (class 2606 OID 914777)
-- Name: affiliate_invitation fk_affinv_master; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.affiliate_invitation
    ADD CONSTRAINT fk_affinv_master FOREIGN KEY (master_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3901 (class 2606 OID 573375)
-- Name: super_vip_history fk_assign_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.super_vip_history
    ADD CONSTRAINT fk_assign_employee FOREIGN KEY (assign_employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3884 (class 2606 OID 573057)
-- Name: team_history fk_bh_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.team_history
    ADD CONSTRAINT fk_bh_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3899 (class 2606 OID 570035)
-- Name: customer_card_access_branch fk_branch; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_card_access_branch
    ADD CONSTRAINT fk_branch FOREIGN KEY (branch_id) REFERENCES sofk_application.branch(id);


--
-- TOC entry 3895 (class 2606 OID 569937)
-- Name: managing_director_rsk fk_c2b_branch; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.managing_director_rsk
    ADD CONSTRAINT fk_c2b_branch FOREIGN KEY (branch_id) REFERENCES sofk_application.branch(id);


--
-- TOC entry 3870 (class 2606 OID 573340)
-- Name: customer_to_employee fk_c2e_shifter_id; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_employee
    ADD CONSTRAINT fk_c2e_shifter_id FOREIGN KEY (shifter_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3916 (class 2606 OID 573132)
-- Name: customer_card_access_employee fk_ccae_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_card_access_employee
    ADD CONSTRAINT fk_ccae_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3892 (class 2606 OID 569889)
-- Name: mutator_changes fk_chd_mutator; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.mutator_changes
    ADD CONSTRAINT fk_chd_mutator FOREIGN KEY (mutator_id) REFERENCES sofk_application.mutators(id);


--
-- TOC entry 3874 (class 2606 OID 570018)
-- Name: branch fk_city; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.branch
    ADD CONSTRAINT fk_city FOREIGN KEY (city_id) REFERENCES sofk_application.city(id);


--
-- TOC entry 3911 (class 2606 OID 573032)
-- Name: customer_to_company fk_company; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_company
    ADD CONSTRAINT fk_company FOREIGN KEY (company_id) REFERENCES sofk_application.company(id);


--
-- TOC entry 3917 (class 2606 OID 570338)
-- Name: customer_to_deleted_employee fk_ctde_branch; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_deleted_employee
    ADD CONSTRAINT fk_ctde_branch FOREIGN KEY (branch_id) REFERENCES sofk_application.branch(id);


--
-- TOC entry 3918 (class 2606 OID 573137)
-- Name: customer_to_deleted_employee fk_ctde_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_deleted_employee
    ADD CONSTRAINT fk_ctde_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3919 (class 2606 OID 573400)
-- Name: customer_to_deleted_employee fk_ctde_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_deleted_employee
    ADD CONSTRAINT fk_ctde_employee FOREIGN KEY (employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3920 (class 2606 OID 573573)
-- Name: customer_to_deleted_employee fk_ctde_rst_group; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_deleted_employee
    ADD CONSTRAINT fk_ctde_rst_group FOREIGN KEY (rst_group_id) REFERENCES sofk_application.rst_group(id);


--
-- TOC entry 3871 (class 2606 OID 569640)
-- Name: customer_to_employee fk_cte2branch; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_employee
    ADD CONSTRAINT fk_cte2branch FOREIGN KEY (branch_id) REFERENCES sofk_application.branch(id);


--
-- TOC entry 3872 (class 2606 OID 573047)
-- Name: customer_to_employee fk_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_employee
    ADD CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3886 (class 2606 OID 573062)
-- Name: customer_prime fk_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_prime
    ADD CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3898 (class 2606 OID 573092)
-- Name: customer_card_access fk_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_card_access
    ADD CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3900 (class 2606 OID 573097)
-- Name: customer_card_access_branch fk_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_card_access_branch
    ADD CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3902 (class 2606 OID 573102)
-- Name: super_vip_history fk_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.super_vip_history
    ADD CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3905 (class 2606 OID 573107)
-- Name: prospect fk_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.prospect
    ADD CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3906 (class 2606 OID 573112)
-- Name: customer_churn fk_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_churn
    ADD CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3912 (class 2606 OID 573117)
-- Name: customer_to_company fk_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_company
    ADD CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3913 (class 2606 OID 573127)
-- Name: customer_privilege fk_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_privilege
    ADD CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3909 (class 2606 OID 573198)
-- Name: customer_churn_notification fk_customer_churn_id; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_churn_notification
    ADD CONSTRAINT fk_customer_churn_id FOREIGN KEY (customer_churn_id) REFERENCES sofk_application.customer_churn(id);


--
-- TOC entry 3929 (class 2606 OID 946961)
-- Name: customer_note fk_customer_note_potential_customer_id; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_note
    ADD CONSTRAINT fk_customer_note_potential_customer_id FOREIGN KEY (potential_customer_id) REFERENCES sofk_application.potential_customers(id);


--
-- TOC entry 3927 (class 2606 OID 946942)
-- Name: customer_to_tag fk_customer_tag_customer_id; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_tag
    ADD CONSTRAINT fk_customer_tag_customer_id FOREIGN KEY (potential_customer_id) REFERENCES sofk_application.potential_customers(id);


--
-- TOC entry 3928 (class 2606 OID 946947)
-- Name: customer_to_tag fk_customer_tag_tag_id; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_tag
    ADD CONSTRAINT fk_customer_tag_tag_id FOREIGN KEY (tag_id) REFERENCES sofk_application.tag(id);


--
-- TOC entry 3883 (class 2606 OID 573360)
-- Name: disclaimer_milestone fk_dm_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.disclaimer_milestone
    ADD CONSTRAINT fk_dm_employee FOREIGN KEY (employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3881 (class 2606 OID 573253)
-- Name: delayed_shift fk_ds_cust2emp; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.delayed_shift
    ADD CONSTRAINT fk_ds_cust2emp FOREIGN KEY (customer_to_employee_id) REFERENCES sofk_application.customer_to_employee(id);


--
-- TOC entry 3882 (class 2606 OID 573355)
-- Name: delayed_shift fk_ds_shifter_emp; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.delayed_shift
    ADD CONSTRAINT fk_ds_shifter_emp FOREIGN KEY (shifter_employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3875 (class 2606 OID 569461)
-- Name: employee_to_branch fk_e2b_branch; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.employee_to_branch
    ADD CONSTRAINT fk_e2b_branch FOREIGN KEY (branch_id) REFERENCES sofk_application.branch(id);


--
-- TOC entry 3876 (class 2606 OID 573345)
-- Name: employee_to_branch fk_e2b_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.employee_to_branch
    ADD CONSTRAINT fk_e2b_employee FOREIGN KEY (employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3877 (class 2606 OID 573568)
-- Name: employee_to_branch fk_e2b_rst_group_id; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.employee_to_branch
    ADD CONSTRAINT fk_e2b_rst_group_id FOREIGN KEY (rst_group_id) REFERENCES sofk_application.rst_group(id);


--
-- TOC entry 3873 (class 2606 OID 573335)
-- Name: customer_to_employee fk_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_to_employee
    ADD CONSTRAINT fk_employee FOREIGN KEY (service_team_member_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3910 (class 2606 OID 573395)
-- Name: customer_churn_notification fk_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_churn_notification
    ADD CONSTRAINT fk_employee FOREIGN KEY (employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3887 (class 2606 OID 569681)
-- Name: customer_prime fk_group_prime; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_prime
    ADD CONSTRAINT fk_group_prime FOREIGN KEY (group_id) REFERENCES sofk_application.group_prime(id);


--
-- TOC entry 3914 (class 2606 OID 570300)
-- Name: customer_privilege fk_group_privilege; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_privilege
    ADD CONSTRAINT fk_group_privilege FOREIGN KEY (group_id) REFERENCES sofk_application.group_privilege(id);


--
-- TOC entry 3907 (class 2606 OID 573390)
-- Name: customer_churn fk_initiator; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_churn
    ADD CONSTRAINT fk_initiator FOREIGN KEY (initiator_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3915 (class 2606 OID 573122)
-- Name: mark_to_sofk_queue fk_m2sofk_queue; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.mark_to_sofk_queue
    ADD CONSTRAINT fk_m2sofk_queue FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3893 (class 2606 OID 573476)
-- Name: mark_to_uasp_queue fk_m2uasp_queue; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.mark_to_uasp_queue
    ADD CONSTRAINT fk_m2uasp_queue FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3896 (class 2606 OID 573365)
-- Name: managing_director_rsk fk_md2b_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.managing_director_rsk
    ADD CONSTRAINT fk_md2b_employee FOREIGN KEY (employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3897 (class 2606 OID 573370)
-- Name: managing_director_central_office fk_md2b_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.managing_director_central_office
    ADD CONSTRAINT fk_md2b_employee FOREIGN KEY (employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3908 (class 2606 OID 573385)
-- Name: customer_churn fk_old_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.customer_churn
    ADD CONSTRAINT fk_old_employee FOREIGN KEY (old_employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3921 (class 2606 OID 570424)
-- Name: potential_customers fk_pc_branch; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.potential_customers
    ADD CONSTRAINT fk_pc_branch FOREIGN KEY (branch_id) REFERENCES sofk_application.branch(id);


--
-- TOC entry 3922 (class 2606 OID 573142)
-- Name: potential_customers fk_pc_customer; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.potential_customers
    ADD CONSTRAINT fk_pc_customer FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3923 (class 2606 OID 573405)
-- Name: potential_customers fk_pc_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.potential_customers
    ADD CONSTRAINT fk_pc_employee FOREIGN KEY (employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3924 (class 2606 OID 573578)
-- Name: potential_customers fk_pc_rst_group; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.potential_customers
    ADD CONSTRAINT fk_pc_rst_group FOREIGN KEY (rst_group_id) REFERENCES sofk_application.rst_group(id);


--
-- TOC entry 3880 (class 2606 OID 573497)
-- Name: person_cs_queue fk_pcs_queue; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.person_cs_queue
    ADD CONSTRAINT fk_pcs_queue FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3891 (class 2606 OID 573532)
-- Name: profile_queue fk_pcs_queue; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.profile_queue
    ADD CONSTRAINT fk_pcs_queue FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


--
-- TOC entry 3890 (class 2606 OID 573556)
-- Name: affiliates fk_relative; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.affiliates
    ADD CONSTRAINT fk_relative FOREIGN KEY (relative_id) REFERENCES sofk_application.relative(id);


--
-- TOC entry 3904 (class 2606 OID 572961)
-- Name: sp_queue_mo fk_sqm_splog; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.sp_queue_mo
    ADD CONSTRAINT fk_sqm_splog FOREIGN KEY (sp_log_id) REFERENCES sofk_application.sp_log(id);


--
-- TOC entry 3885 (class 2606 OID 569634)
-- Name: service_team_import_status fk_sti2branch; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.service_team_import_status
    ADD CONSTRAINT fk_sti2branch FOREIGN KEY (branch_id) REFERENCES sofk_application.branch(id);


--
-- TOC entry 3878 (class 2606 OID 573248)
-- Name: temporary_shift fk_ts_cust2emp; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.temporary_shift
    ADD CONSTRAINT fk_ts_cust2emp FOREIGN KEY (customer_to_employee_id) REFERENCES sofk_application.customer_to_employee(id);


--
-- TOC entry 3879 (class 2606 OID 573350)
-- Name: temporary_shift fk_ts_return_emp; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.temporary_shift
    ADD CONSTRAINT fk_ts_return_emp FOREIGN KEY (return_employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3903 (class 2606 OID 573380)
-- Name: super_vip_history fk_unassign_employee; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.super_vip_history
    ADD CONSTRAINT fk_unassign_employee FOREIGN KEY (unassign_employee_id) REFERENCES sofk_application.employee(id);


--
-- TOC entry 3894 (class 2606 OID 573668)
-- Name: vip_to_fl_queue fk_vip2fl_queue; Type: FK CONSTRAINT; Schema: sofk_application; Owner: -
--

ALTER TABLE ONLY sofk_application.vip_to_fl_queue
    ADD CONSTRAINT fk_vip2fl_queue FOREIGN KEY (customer_id) REFERENCES sofk_application.customer(id);


-- Completed on 2026-07-28 21:27:25

--
-- PostgreSQL database dump complete
--

