CREATE TABLE employee (
    employee_id SERIAL PRIMARY KEY,
    full_name VARCHAR(128) NOT NULL,
    role VARCHAR(64) NOT NULL CHECK (role IN (
        'sales_staff',
        'warehouse_staff',
        'warehouse_manager',
        'store_manager',
        'accountant'
    )),
    age INT,
    national_id VARCHAR(32) NOT NULL,
    gender CHAR(1) CHECK (gender IN ('M', 'F')),
    address VARCHAR(256),
    phone VARCHAR(32) NOT NULL,
    email VARCHAR(128),
    salary NUMERIC(15,2) NOT NULL,
    password VARCHAR(128) NOT NULL,
    employment_status VARCHAR(32) NOT NULL CHECK (employment_status IN (
        'active',
        'on_leave',
        'on_maternity_leave',
        'contract_suspended',
        'probation',
        'suspended',
        'resigned'
    ))
);

CREATE TABLE product (
    product_id SERIAL PRIMARY KEY,
    product_name VARCHAR(128) NOT NULL,
    product_type VARCHAR(64) NOT NULL,
    price NUMERIC(15,2) NOT NULL,
    unit VARCHAR(16),
    stock_quantity INT DEFAULT 0,
    description TEXT
);

CREATE TABLE customer (
    customer_id SERIAL PRIMARY KEY,
    full_name VARCHAR(128) NOT NULL,
    gender CHAR(1) CHECK (gender IN ('M', 'F')),
    date_of_birth DATE,
    phone VARCHAR(32) NOT NULL,
    email VARCHAR(128),
    member_points INT DEFAULT 0,
    rank VARCHAR(16) CHECK (rank IN ('silver', 'gold', 'diamond')),
    cart TEXT,
    registration_date DATE DEFAULT CURRENT_DATE,
    status VARCHAR(32) DEFAULT 'active' CHECK (status IN ('active', 'blocked', 'inactive')),
    password VARCHAR(128)
);

CREATE TABLE customer_order (
    order_id SERIAL PRIMARY KEY,
    customer_id INT REFERENCES customer(customer_id),
    employee_id INT REFERENCES employee(employee_id),
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    total_amount NUMERIC(15,2),
    payment_method VARCHAR(32),
    order_status VARCHAR(32) CHECK (order_status IN (
        'pending',
        'approved',
        'shipping',
        'delivered',
        'paid'
    )),
    note TEXT
);

CREATE TABLE employment_contract (
    contract_id SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employee(employee_id),
    contract_date DATE,
    duration VARCHAR(64),
    termination_reason TEXT,
    termination_date DATE,
    content TEXT
);

CREATE TABLE warehouse (
    warehouse_id SERIAL PRIMARY KEY,
    warehouse_name VARCHAR(128),
    category VARCHAR(64)
);

CREATE TABLE batch (
    batch_id SERIAL PRIMARY KEY,
    product_id INT REFERENCES product(product_id),
    import_date DATE,
    expiry_date DATE,
    purchase_price NUMERIC(15,2),
    quantity INT,
    warehouse_location VARCHAR(64),
    note TEXT
);

CREATE TABLE order_detail (
    order_detail_id SERIAL PRIMARY KEY,
    order_id INT REFERENCES customer_order(order_id),
    product_id INT REFERENCES product(product_id),
    batch_id INT REFERENCES batch(batch_id),
    quantity INT NOT NULL,
    product_price NUMERIC(15,2) NOT NULL,
    total_price NUMERIC(15,2) NOT NULL
);

CREATE TABLE warehouse_category (
    warehouse_category_id SERIAL PRIMARY KEY,
    name VARCHAR(64) NOT NULL
);

CREATE TABLE product_category (
    product_category_id SERIAL PRIMARY KEY,
    name VARCHAR(64) NOT NULL,
    warehouse_category_id INT NOT NULL REFERENCES warehouse_category(warehouse_category_id)
        -- category of warehouse allowed for this product type
);

ALTER TABLE warehouse
ADD COLUMN warehouse_category_id INT REFERENCES warehouse_category(warehouse_category_id);

ALTER TABLE product
ADD COLUMN product_category_id INT REFERENCES product_category(product_category_id);

CREATE OR REPLACE FUNCTION check_batch_warehouse_category()
RETURNS TRIGGER AS $$
DECLARE
    prod_cat_id INT;
    allowed_warehouse_cat_id INT;
    actual_warehouse_cat_id INT;
BEGIN
    -- Get the product category id from product
    SELECT product_category_id INTO prod_cat_id
    FROM product
    WHERE product_id = NEW.product_id;

    -- Get the allowed warehouse category id for this product category
    SELECT warehouse_category_id INTO allowed_warehouse_cat_id
    FROM product_category
    WHERE product_category_id = prod_cat_id;

    -- Get the warehouse category id from warehouse
    SELECT warehouse_category_id INTO actual_warehouse_cat_id
    FROM warehouse
    WHERE warehouse_id = NEW.warehouse_id;

    -- Check if allowed and actual warehouse category are the same
    IF allowed_warehouse_cat_id IS NULL OR actual_warehouse_cat_id IS NULL OR allowed_warehouse_cat_id <> actual_warehouse_cat_id THEN
        RAISE EXCEPTION 'Cannot insert batch: Product category only allowed in warehouse category %, but this warehouse has category %',
            allowed_warehouse_cat_id, actual_warehouse_cat_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_batch_warehouse_category
BEFORE INSERT ON batch
FOR EACH ROW
EXECUTE FUNCTION check_batch_warehouse_category();

alter table warehouse drop column category;
 alter table batch alter column product_id set not null;
alter table batch alter column import_date set not null;
alter table batch alter column purchase_price set not null;
alter table batch alter column quantity set not null;
alter table batch alter column warehouse_id set not null;

INSERT INTO warehouse_category (name) VALUES
('Cold Storage'),     -- Kho lạnh
('Cool Storage'),     -- Kho mát
('Dry Storage'),      -- Kho khô
('General Goods'),    -- Kho gia dụng
('Chemical Storage'), -- Kho hóa chất
('Transit Storage'),  -- Kho tạm
('Finished Goods');   -- Kho thành phẩm

-- Giả sử warehouse_category_id lần lượt từ 1 đến 7 như trên
INSERT INTO product_category (name, warehouse_category_id) VALUES
('Fresh Food', 1),                -- Thịt, cá, hải sản, kem, sữa, dược phẩm
('Vegetables & Fruits', 2),       -- Rau củ, trái cây, sữa, nước giải khát
('Dry Food & Cosmetics', 3),      -- Đồ khô, bánh kẹo, đồ hộp, mỹ phẩm
('Household Appliances', 4),      -- Đồ gia dụng, điện tử, văn phòng phẩm
('Chemicals', 5),                 -- Hóa chất, tẩy rửa, sơn, phân bón
('Transit Goods', 6),             -- Hàng chuyển tiếp
('Finished Products', 7);         -- Hàng đã sản xuất xong

delete from product_category where product_category_id in(6,7);

CREATE OR REPLACE FUNCTION check_expiry_date_not_null()
RETURNS TRIGGER AS $$
DECLARE
    prod_cat_id INT;
BEGIN
    SELECT product_category_id INTO prod_cat_id
    FROM product
    WHERE product_id = NEW.product_id;

    IF prod_cat_id IN (1,2,3,5) AND NEW.expiry_date IS NULL THEN
        RAISE EXCEPTION 'expiry_date cannot be NULL for this product category (id %)', prod_cat_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_expiry_date_not_null
BEFORE INSERT OR UPDATE ON batch
FOR EACH ROW
EXECUTE FUNCTION check_expiry_date_not_null();

-- tao trigger khi them lo hang moi thi cap nhat product ton kho tuong ung

CREATE OR REPLACE FUNCTION increase_product_stock_on_batch_insert()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE product
    SET stock_quantity = stock_quantity + NEW.quantity
    WHERE product_id = NEW.product_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_increase_product_stock_on_batch_insert
AFTER INSERT ON batch
FOR EACH ROW
EXECUTE FUNCTION increase_product_stock_on_batch_insert();

-- chen 10 kho moi
INSERT INTO warehouse (warehouse_name, warehouse_category_id) VALUES
('Cold Store 1', 1),
('Cool Store 1', 2),
('Dry Store 1', 3),
('General Store 1', 4),
('Chemical Store 1', 5),
('Transit Store 1', 6),
('Finished Goods 1', 7),
('Cold Store 2', 1),
('Cool Store 2', 2),
('General Store 2', 4);

-- xoa rang buoc khoa ngoai category_id cua warehouse 
alter table warehouse drop constraint warehouse_warehouse_category_id_fkey;

-- tao lai rang buoc moi de set null khi categroy_id bi xoa o bang khac
alter table warehouse
add constraint warehouse_warehouse_category_id_fkey
foreign key (warehouse_category_id) references warehouse_category(warehouse_category_id)
on delete set null;

-- tao trigger de khi chen nhan vien moi thi trang thai la pending
CREATE OR REPLACE FUNCTION enforce_pending_on_insert()
RETURNS trigger AS $$
BEGIN
    NEW.employment_status := 'pending';
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- xoa cac trang thai cho phep cua nhan vien
ALTER TABLE employee
DROP CONSTRAINT employee_employment_status_check;

-- them lai
ALTER TABLE employee
ADD CONSTRAINT employee_employment_status_check CHECK (
    employment_status::text = ANY (ARRAY[
        'active'::character varying,
        'on_leave'::character varying,
        'on_maternity_leave'::character varying,
        'contract_suspended'::character varying,
        'probation'::character varying,
        'suspended'::character varying,
        'resigned'::character varying,
        'pending'::character varying  
    ]::text[])
);

-- trigger tu dong dat la pending khi insert
CREATE OR REPLACE FUNCTION enforce_pending_on_insert()
RETURNS trigger AS $$
BEGIN
    NEW.employment_status := 'pending';
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_enforce_pending_on_insert
BEFORE INSERT ON employee
FOR EACH ROW
EXECUTE FUNCTION enforce_pending_on_insert();

-- trigger kiem tra khi doi trang thai nhan vien, neu chua co hop dong thi van la pending
CREATE OR REPLACE FUNCTION enforce_contract_on_status_change()
RETURNS trigger AS $$
BEGIN
    IF NEW.employment_status <> 'pending' THEN
        IF NOT EXISTS (SELECT 1 FROM employment_contract WHERE employee_id = NEW.employee_id) THEN
            NEW.employment_status := 'pending';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_enforce_contract_on_status_change
BEFORE UPDATE OF employment_status ON employee
FOR EACH ROW
EXECUTE FUNCTION enforce_contract_on_status_change();

-- chen 10 nhan vien moi
INSERT INTO employee (
    full_name, role, age, national_id, gender, address, phone, email, salary, password
) VALUES
('Alice Johnson', 'sales_staff', 25, 'ID001', 'F', '123 Main St', '0123456789', 'alice@example.com', 800.00, 'alicepass'),
('Bob Smith', 'warehouse_staff', 30, 'ID002', 'M', '456 First Ave', '0123456790', 'bob@example.com', 900.00, 'bobpass'),
('Carol Lee', 'warehouse_manager', 35, 'ID003', 'F', '789 North Rd', '0123456791', 'carol@example.com', 1200.00, 'carolpass'),
('David Kim', 'store_manager', 40, 'ID004', 'M', '321 South St', '0123456792', 'david@example.com', 1500.00, 'davidpass'),
('Eva Green', 'accountant', 28, 'ID005', 'F', '654 West St', '0123456793', 'eva@example.com', 950.00, 'evapass'),
('Frank Brown', 'sales_staff', 32, 'ID006', 'M', '987 East Ave', '0123456794', 'frank@example.com', 820.00, 'frankpass'),
('Grace Lee', 'warehouse_staff', 29, 'ID007', 'F', '147 Park Blvd', '0123456795', 'grace@example.com', 880.00, 'gracepass'),
('Henry Ford', 'warehouse_manager', 38, 'ID008', 'M', '258 Garden Dr', '0123456796', 'henry@example.com', 1100.00, 'henrypass'),
('Ivy Nguyen', 'store_manager', 27, 'ID009', 'F', '369 Lake St', '0123456797', 'ivy@example.com', 1450.00, 'ivypass'),
('Jack White', 'accountant', 31, 'ID010', 'M', '753 Hill Rd', '0123456798', 'jack@example.com', 970.00, 'jackpass');


-- sua lai trigger kiem tra cap nhat stauts
CREATE OR REPLACE FUNCTION enforce_contract_on_status_change()
RETURNS trigger AS $$
BEGIN
    IF NEW.employment_status <> 'pending' THEN
        IF NOT EXISTS (SELECT 1 FROM employment_contract WHERE employee_id = NEW.employee_id) THEN
            RAISE EXCEPTION 'No contract: cannot change status from pending.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- thay doi trong employment_contract: xoa duration, thay bang thoi han ket thuc hop dong
alter table employment_contract add column contract_end_date date;
alter table employment_contract drop column duration;

-- chen hop dong moi cho 2,3,5,6,9,10
INSERT INTO employment_contract (employee_id, contract_date, contract_end_date, content)
VALUES
(2, '2024-06-01', '2026-06-01', 'Labor contract for Bob Smith'),
(3, '2024-06-01', '2026-06-01', 'Labor contract for Carol Lee'),
(5, '2024-06-01', '2026-06-01', 'Labor contract for Eva Green'),
(6, '2024-06-01', '2026-06-01', 'Labor contract for Frank Brown'),
(9, '2024-06-01', '2026-06-01', 'Labor contract for Ivy Nguyen'),
(10, '2024-06-01', '2026-06-01', 'Labor contract for Jack White');

-- them truong moi cho contract: ngay nhan vien bat dau lam viec
alter table employment_contract add column effective_date date;

-- them effective_date
UPDATE employment_contract
SET effective_date = '2024-06-10'
WHERE contract_id IN (1, 2, 3, 4, 5, 6);

-- update trang thai lam viec cua nhan vien
update employee set employment_status = 'active' where employee_id in (select employee_id from employment_contract);

-- sua lai trigger kiem tra trang thai nhan vien
CREATE OR REPLACE FUNCTION enforce_contract_on_status_change()
RETURNS trigger AS $$
DECLARE
    v_end_date date;
BEGIN
    IF NEW.employment_status <> 'pending' THEN
        -- Check if contract exists and get contract_end_date
        SELECT contract_end_date INTO v_end_date
        FROM employment_contract
        WHERE employee_id = NEW.employee_id
        ORDER BY contract_end_date DESC
        LIMIT 1;
        
        IF v_end_date IS NULL THEN
            RAISE EXCEPTION 'No contract: cannot change status from pending.';
        END IF;
        
        -- Check if contract still effective
        IF v_end_date < CURRENT_DATE THEN
            RAISE EXCEPTION 'Contract expired: cannot change status from pending.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- chen cho nhan vien 7 da het han
INSERT INTO employment_contract (
    employee_id, 
    contract_date, 
    effective_date, 
    contract_end_date, 
    termination_reason, 
    termination_date, 
    content
) VALUES (
    7,
    '2022-06-01',        -- Ngày ký hợp đồng (ví dụ 2 năm trước)
    '2022-06-10',        -- Ngày bắt đầu làm việc
    '2023-06-10',        -- Ngày kết thúc hợp đồng (đã hết hạn, ví dụ 1 năm trước)
    'Contract ended normally', -- Lý do chấm dứt
    '2023-06-10',        -- Ngày chấm dứt (cùng ngày kết thúc)
    'Expired labor contract for Grace Lee'
);

-- sua lai trigger kiem tra status
CREATE OR REPLACE FUNCTION enforce_contract_on_status_change()
RETURNS trigger AS $$
DECLARE
    v_end_date date;
BEGIN
    SELECT contract_end_date INTO v_end_date
    FROM employment_contract
    WHERE employee_id = NEW.employee_id
    ORDER BY contract_end_date DESC
    LIMIT 1;

    IF v_end_date IS NULL THEN
        IF NEW.employment_status <> 'pending' THEN
            RAISE EXCEPTION 'No contract: only pending status allowed.';
        END IF;
        RETURN NEW;
    END IF;

    IF v_end_date < CURRENT_DATE THEN
        IF NEW.employment_status NOT IN ('pending', 'resigned') THEN
            RAISE EXCEPTION 'Contract expired: only pending or resigned status allowed.';
        END IF;
        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- them rang buoc de stock quantity luon >=0
ALTER TABLE product
ADD CONSTRAINT chk_product_stock_quantity_non_negative
CHECK (stock_quantity >= 0);

-- neu chen stock quantity lon hon 0, thong bao loi
CREATE OR REPLACE FUNCTION check_zero_stock_quantity()
RETURNS trigger AS $$
BEGIN
    IF NEW.stock_quantity IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 
        'Stock quantity must be 0 when adding a new product. If you want to increase stock, please create a new batch.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_check_zero_stock_quantity
BEFORE INSERT ON product
FOR EACH ROW
EXECUTE FUNCTION check_zero_stock_quantity();

-- chen 20 san pham moi
-- Fresh Food (product_category_id = 1)
INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Pork Loin', 'Meat', 80000, 'kg', 1);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Chicken Breast', 'Meat', 70000, 'kg', 1);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Salmon Fillet', 'Fish', 150000, 'kg', 1);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Beef Steak', 'Meat', 200000, 'kg', 1);

-- Vegetables & Fruits (product_category_id = 2)
INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Cabbage', 'Vegetable', 15000, 'piece', 2);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Tomato', 'Vegetable', 25000, 'kg', 2);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Banana', 'Fruit', 30000, 'kg', 2);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Apple', 'Fruit', 50000, 'kg', 2);

-- Dry Food & Cosmetics (product_category_id = 3)
INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Instant Noodles', 'Dry Food', 7000, 'pack', 3);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Shampoo', 'Cosmetic', 45000, 'bottle', 3);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Toothpaste', 'Cosmetic', 30000, 'tube', 3);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Rice', 'Dry Food', 18000, 'kg', 3);

-- Household Appliances (product_category_id = 4)
INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Electric Kettle', 'Appliance', 350000, 'piece', 4);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Frying Pan', 'Appliance', 180000, 'piece', 4);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Rice Cooker', 'Appliance', 600000, 'piece', 4);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Microwave Oven', 'Appliance', 1800000, 'piece', 4);

-- Chemicals (product_category_id = 5)
INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Laundry Detergent', 'Chemical', 120000, 'bottle', 5);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Dishwashing Liquid', 'Chemical', 40000, 'bottle', 5);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Bleach', 'Chemical', 25000, 'bottle', 5);

INSERT INTO product (product_name, product_type, price, unit, product_category_id)
VALUES ('Glass Cleaner', 'Chemical', 30000, 'bottle', 5);

-- khong cho phep duoc tu do update stock_quantity, no chi duoc updat ekhi them batch moi
CREATE OR REPLACE FUNCTION prevent_manual_stock_quantity_update()
RETURNS trigger AS $$
BEGIN
    IF NEW.stock_quantity IS DISTINCT FROM OLD.stock_quantity THEN
        RAISE EXCEPTION 'You cannot manually update stock_quantity. Stock quantity is only updated automatically when adding a new batch.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_manual_stock_quantity_update
BEFORE UPDATE ON product
FOR EACH ROW
EXECUTE FUNCTION prevent_manual_stock_quantity_update();

-- trigger them tu dong stock quantity khi the batch moi
CREATE OR REPLACE FUNCTION increase_product_stock_on_batch_insert()
RETURNS trigger AS $$
BEGIN
    UPDATE product
    SET stock_quantity = stock_quantity + NEW.quantity
    WHERE product_id = NEW.product_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- xoa trigger kiem tra stock quantity, ly do: phuc tap
DROP TRIGGER IF EXISTS trg_prevent_manual_stock_quantity_update ON product;



-- xoa stock quantity o product
alter table product drop column stock_quantity;

-- them truong so luong con lai o batch, luon >=0
alter table batch add column remaining_quantity integer not null default 0;
ALTER TABLE batch
ADD CONSTRAINT chk_batch_remaining_quantity_non_negative
CHECK (remaining_quantity >= 0);

-- trigger dat remaining quantity = so luong nhap khi  nhap lo moi
CREATE OR REPLACE FUNCTION set_remaining_quantity_on_batch_insert()
RETURNS trigger AS $$
BEGIN
    NEW.remaining_quantity := NEW.quantity;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_set_remaining_quantity_on_batch_insert
BEFORE INSERT ON batch
FOR EACH ROW
EXECUTE FUNCTION set_remaining_quantity_on_batch_insert();

-- xoa trigger, function cap nhat stock_quantity
DROP TRIGGER IF EXISTS trg_increase_product_stock_on_batch_insert ON batch;
DROP FUNCTION IF EXISTS increase_product_stock_on_batch_insert();

-- chen 10 lo hang moi
INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (1,  '2024-06-01', '2024-12-01', 75000, 20, 1);

INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (2,  '2024-06-01', '2024-12-01', 68000, 15, 1);

INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (3,  '2024-06-01', '2024-11-15', 148000, 10, 1);

INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (4,  '2024-06-01', '2024-11-30', 190000, 5, 1);

INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (5,  '2024-06-01', '2024-07-10', 14000, 50, 2);

INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (6,  '2024-06-01', '2024-07-10', 22000, 40, 2);

INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (7,  '2024-06-01', '2024-06-30', 29000, 25, 2);

INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (8,  '2024-06-01', '2024-07-31', 48000, 30, 2);

INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (9,  '2024-06-01', '2025-06-01', 6500, 100, 3);

INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (10, '2024-06-01', '2026-06-01', 44000, 60, 3);

INSERT INTO batch (product_id, import_date, expiry_date, purchase_price, quantity, warehouse_id)
VALUES (16, '2024-06-01', NULL, 1700000, 5, 4);
