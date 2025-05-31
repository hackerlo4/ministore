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
